import AssemblyAI
import Foundation
import Observation

/// "Sign in with AssemblyAI": the alternative to pasting a key. The member signs
/// in and approves Blurt on AssemblyAI's consent page; Blurt trades the access
/// token for the connection's own API key and stores that key exactly where a
/// pasted one goes, so the transcriber, the readiness gate and Settings read it
/// the same way. What signing in adds is renewal (a refresh and an exchange at
/// most once a day, which also picks up a rotated key) and a real sign-out
/// (which ends the connection server-side, not just here).
///
/// The shell owns the browser (`ASWebAuthenticationSession`); this owns
/// everything either side of it, so the rules are unit-tested.
@MainActor
@Observable
public final class AssemblyAIAccount {
  public enum Status: Sendable, Equatable {
    case signedOut
    /// `email` is nil when the ID token didn't carry one.
    case signedIn(email: String?)

    /// The account row's text while signed in; nil while signed out, when the
    /// row shows only its button.
    public var statusText: String? {
      switch self {
      case .signedOut: nil
      case .signedIn(let email?): "Signed in as \(email)"
      case .signedIn(nil): "Signed in"
      }
    }
  }

  private static let log = HostIdentity.current.logger("Account")

  /// How often the running app asks `renewIfDue()`. Blurt runs for days from
  /// the trigger key without coming forward, so launch alone isn't enough; a
  /// check that isn't due costs a Keychain read.
  public static let renewalCheckInterval: Duration = .seconds(60 * 60)

  /// Whether this build has a Connected App configured. Builds without one
  /// (today: release) show only the paste-a-key path.
  public var isAvailable: Bool { configuration != nil }
  public private(set) var status: Status {
    didSet { syncDictationOrigin() }
  }

  /// The dictation host for the current sign-in, for the transcriber. Set to
  /// `dictationHost` while signed in, nil otherwise.
  public nonisolated let dictationOrigin = DictationOrigin()

  @ObservationIgnored private let configuration: OAuthConfiguration?
  /// Where this sign-in's keys dictate; nil means production.
  @ObservationIgnored private let dictationHost: URL?
  @ObservationIgnored private let apiKey: APIKeyModel
  @ObservationIgnored private let store: SignInStore
  @ObservationIgnored private let client: OAuthClient?
  @ObservationIgnored private let now: @Sendable () -> Date
  /// The renewal in flight, which `signOut()` waits out: the renewal may have
  /// rotated the refresh token, and refreshing with the old one would read as
  /// "already over".
  @ObservationIgnored private var renewal: Task<Void, Never>?
  /// Bumped whenever the stored session is replaced or dropped (a sign-in, a
  /// sign-out, a reset). A renewal suspends twice on the network; one that wakes
  /// to a different generation writes nothing, or it would bring back a session
  /// the user just ended.
  @ObservationIgnored private var generation = 0

  public init(
    configuration: OAuthConfiguration?,
    dictationHost: URL? = nil,
    apiKey: APIKeyModel,
    store: SignInStore = .production,
    transport: any HTTPTransport = URLSession.shared,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.dictationHost = dictationHost
    self.apiKey = apiKey
    self.store = store
    self.client = configuration.map {
      OAuthClient(configuration: $0, transport: transport, userAgent: UserAgent.current)
    }
    self.now = now
    // An unreadable item (a locked Keychain at launch) starts as signed out;
    // `refreshStatus()` catches up once it reads.
    if case .session(let session) = store.load {
      self.status = .signedIn(email: session.email)
    } else {
      self.status = .signedOut
    }
    // `didSet` doesn't run for the initial value.
    syncDictationOrigin()
  }

  private func syncDictationOrigin() {
    dictationOrigin.set(status == .signedOut ? nil : dictationHost)
  }

  /// The session storage, for the install reset's sweep (the in-memory store
  /// under UI testing). `refreshStatus()` catches `status` up afterwards.
  public var storage: SignInStore { store }

  /// Re-reads the session item and updates `status`, leaving it alone when the
  /// item can't be read. Called when the account UI appears, like
  /// `APIKeyModel.refreshStatus()`.
  public func refreshStatus() {
    switch store.load {
    case .session(let session): status = .signedIn(email: session.email)
    case .none: status = .signedOut
    case .unavailable: break
    }
  }

  /// A new sign-in attempt for the shell to open, or nil when sign-in isn't
  /// configured.
  public func beginSignIn() -> OAuthAuthorization? {
    configuration.map { OAuthAuthorization(configuration: $0) }
  }

  /// Finishes a sign-in from the consent page's redirect: code → tokens → key,
  /// then stores both. Nothing is stored unless every step succeeds, so a failed
  /// attempt leaves whatever was there (a pasted key, or nothing) as it was.
  public func completeSignIn(_ authorization: OAuthAuthorization, callback: URL) async -> SignInOutcome {
    guard let client else { return .failed(.unavailable) }
    let code: String
    do throws(OAuthAuthorization.CallbackError) {
      code = try authorization.code(fromCallback: callback)
    } catch .denied {
      return .cancelled
    } catch {
      // The callback's error, never its code.
      Self.log.error("sign-in callback refused: \(String(describing: error), privacy: .public)")
      return .failed(.consent)
    }
    do throws(OAuthClient.Failure) {
      let tokens = try await client.tokens(for: authorization, code: code)
      guard let refreshToken = tokens.refreshToken else {
        Self.log.error("token response carried no refresh token (offline_access not granted?)")
        return .failed(.server)
      }
      let key = try await client.apiKey(accessToken: tokens.accessToken)
      let session = SignInSession(
        refreshToken: refreshToken, email: tokens.email, keyExpiresAt: key.expiresAt, renewedAt: now())
      generation += 1
      guard store.save(session), apiKey.save(key.apiKey) else {
        store.save(nil)
        return .failed(.keychain)
      }
      status = .signedIn(email: session.email)
      return .signedIn
    } catch {
      return .failed(SignInFailure(error))
    }
  }

  /// Asks `renewIfDue()` now and then every `interval` until cancelled. The
  /// shell starts it once at launch.
  public func runRenewal<C: Clock<Duration>>(
    every interval: Duration = AssemblyAIAccount.renewalCheckInterval, clock: C = ContinuousClock()
  ) async {
    while !Task.isCancelled {
      await renewIfDue()
      do { try await clock.sleep(for: interval) } catch { return }
    }
  }

  /// Refreshes and re-exchanges when `SignInSession.isRenewalDue` says so. A
  /// refused refresh or exchange means the connection is over (revoked from the
  /// dashboard, the member removed, the refresh token lapsed), so the key and
  /// session go and the row offers sign-in again. An unreachable server, or an
  /// unreadable session item, changes nothing; the next check tries again.
  public func renewIfDue() async {
    if let renewal { return await renewal.value }
    guard case .session(let session) = store.load,
      session.isRenewalDue(now: now(), hasKey: apiKey.current != nil)
    else { return }
    let task = Task { await renew(session) }
    renewal = task
    await task.value
    renewal = nil
  }

  /// Ends the connection server-side, then forgets it here. Returns the failure
  /// to show, with everything left in place, when the server couldn't confirm:
  /// the connection is still live and its key still works, so claiming a
  /// sign-out would be wrong. A refresh token the server already refuses means
  /// the connection is already over, which counts as signed out. Nil on success.
  public func signOut() async -> APIKeySubmission.FailureReport? {
    if let renewal { await renewal.value }
    let session: SignInSession
    switch store.load {
    case .session(let stored): session = stored
    case .none:
      forget()
      return nil
    case .unavailable:
      return .inline(message: Self.keychainUnreadableMessage)
    }
    // A build without sign-in configured can't reach the server, but the
    // session it inherited must still be removable: forget it here.
    guard let client else {
      forget()
      return nil
    }
    do throws(OAuthClient.Failure) {
      let tokens = try await client.refresh(session.refreshToken)
      try await client.revoke(accessToken: tokens.accessToken)
    } catch .rejected {
      // Nothing left server-side to end.
    } catch {
      return .inline(message: Self.signOutUnconfirmedMessage)
    }
    forget()
    return nil
  }

  static let signOutUnconfirmedMessage =
    "AssemblyAI couldn’t confirm the sign-out, so Blurt is still connected. Check your connection and try again."
  static let keychainUnreadableMessage =
    "Blurt couldn’t read your sign-in from the macOS Keychain. Check Keychain access and try again."

  /// Drops the session and its key from this Mac without telling the server,
  /// for a connection the server already ended.
  func forget() {
    generation += 1
    store.save(nil)
    apiKey.clear()
    status = .signedOut
  }

  private func renew(_ session: SignInSession) async {
    guard let client else { return }
    let started = generation
    var session = session
    do throws(OAuthClient.Failure) {
      let tokens = try await client.refresh(session.refreshToken)
      guard generation == started else { return }
      // Keep a rotated refresh token before anything else can fail: the old one
      // is already dead.
      if let rotated = tokens.refreshToken { session.refreshToken = rotated }
      session.email = tokens.email ?? session.email
      store.save(session)
      let key = try await client.apiKey(accessToken: tokens.accessToken)
      guard generation == started else { return }
      session.keyExpiresAt = key.expiresAt
      session.renewedAt = now()
      if apiKey.current != key.apiKey { apiKey.save(key.apiKey) }
      store.save(session)
      status = .signedIn(email: session.email)
    } catch .unreachable {
      return
    } catch {
      if generation == started { forget() }
    }
  }
}

/// How a sign-in attempt ended.
public enum SignInOutcome: Sendable, Equatable {
  case signedIn
  /// The member closed the window or declined on the consent page. Nothing to
  /// report.
  case cancelled
  case failed(SignInFailure)
}

/// Why a sign-in failed, with the wording the shell shows. Owned here, next to
/// the outcomes, so the shell renders one judgement instead of assembling text
/// at an alert call site no test reaches.
public enum SignInFailure: Sendable, Equatable {
  /// This build has no Connected App configured.
  case unavailable
  /// The redirect didn't answer this attempt or reported an error.
  case consent
  /// The exchange refused this member; carries the server's reason.
  case forbidden(String?)
  /// A credential was refused mid-flow (an expired code, a revoked grant).
  case rejected
  /// Couldn't reach AssemblyAI, or it failed.
  case server
  /// The key or the session couldn't be written to the Keychain.
  case keychain

  init(_ failure: OAuthClient.Failure) {
    switch failure {
    case .rejected: self = .rejected
    case .forbidden(let reason): self = .forbidden(reason)
    case .unreachable: self = .server
    }
  }

  /// How to report it: inline beside the row for anything a retry (or an admin)
  /// can fix, an alert only for the Keychain fault retrying can't touch. The
  /// same split `APIKeySubmission.Outcome.failureReport` makes for a pasted key.
  public var failureReport: APIKeySubmission.FailureReport {
    switch self {
    case .keychain: .alert(title: "Couldn’t Save Your Sign-In", message: message)
    default: .inline(message: message)
    }
  }

  var message: String {
    switch self {
    case .unavailable:
      "Signing in isn’t available in this version of Blurt. Use an API key instead."
    case .consent, .rejected:
      "AssemblyAI didn’t complete the sign-in. Try again."
    case .forbidden(let reason):
      reason.map { "AssemblyAI didn’t allow it: \($0)" }
        ?? "AssemblyAI didn’t allow Blurt to use your account. Ask an admin of your organization."
    case .server:
      "Couldn’t reach AssemblyAI. Check your connection and try again."
    case .keychain:
      "Blurt couldn’t write to your macOS Keychain. Check Keychain access and try again."
    }
  }
}
