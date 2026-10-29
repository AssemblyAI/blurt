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

  /// The longest `runRenewal` sleeps between checks. A renewal is normally
  /// due days away, and the loop sleeps until then; the cap bounds how long a
  /// sign-in made while it sleeps waits for its schedule, and how far a
  /// changed system clock can throw it.
  public static let longestRenewalSleep: TimeInterval = 24 * 60 * 60
  /// The shortest: a renewal that keeps failing (offline) retries no faster.
  public static let shortestRenewalSleep: TimeInterval = 60
  /// How soon `runRenewal` looks again at a session item it couldn't read (a
  /// locked Keychain): soon enough that a key due in the meantime still
  /// renews, and the status catches up once the Keychain unlocks.
  public static let unreadableSessionRecheck: TimeInterval = 5 * 60
  /// A rejected key renews at once, but no more often than this, so repeated
  /// dictation failures can't hammer the token endpoint.
  public static let rejectedKeyRenewalSpacing: TimeInterval = 15 * 60

  /// Whether this build has a Connected App configured. Builds without one
  /// (a dev build with no local sign-in config) show only the paste-a-key path.
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
  /// While `signOut()` is talking to the server, no renewal may start: it
  /// would present the same refresh token the sign-out is about to rotate,
  /// which reads as reuse and can end the grant mid-sign-out.
  @ObservationIgnored private var signingOut = false
  /// When a rejected key last forced a renewal (`keyWasRejected`).
  @ObservationIgnored private var lastForcedRenewal: Date?
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
    self.status = store.load.session.map { .signedIn(email: $0.email) } ?? .signedOut
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
    updateStatus(from: store.load)
  }

  private func updateStatus(from load: SignInStore.Load) {
    let read: Status
    switch load {
    case .session(let session): read = .signedIn(email: session.email)
    case .none: read = .signedOut
    case .unavailable: return
    }
    // `@Observable` notifies on every write, unchanged or not.
    if read != status { status = read }
  }

  /// A new sign-in attempt for the shell to open, or nil when sign-in isn't
  /// configured.
  public func beginSignIn() -> OAuthAuthorization? {
    configuration.map { OAuthAuthorization(configuration: $0) }
  }

  /// Finishes a sign-in from the consent page's redirect: code → tokens → key,
  /// then stores both. Nothing is stored unless every step succeeds, so a failed
  /// attempt leaves whatever was there (a pasted key, an earlier sign-in, or
  /// nothing) as it was.
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
        refreshToken: refreshToken, email: tokens.email, keyExpiresAt: key.expiresAt,
        keyRotatesAt: key.rotatesAt, renewedAt: now())
      // A renewal of the session this replaces may be mid-flight with a rotated
      // refresh token; let it land, so a failed write below can put it back.
      if let renewal { await renewal.value }
      guard storeSignIn(session, key: key.apiKey) else {
        // Nothing on this Mac can renew or revoke the grant just minted, so end
        // it now. Best effort: the user is told the sign-in failed either way.
        try? await client.revoke(accessToken: tokens.accessToken)
        return .failed(.keychain)
      }
      status = .signedIn(email: session.email)
      return .signedIn
    } catch {
      return .failed(SignInFailure(error))
    }
  }

  /// Writes a new sign-in's session and key, or neither: when the Keychain
  /// refuses the key, the session item goes back to what it held before.
  private func storeSignIn(_ session: SignInSession, key: String) -> Bool {
    let previous = store.load
    guard store.save(session) else { return false }
    guard apiKey.save(key) else {
      store.save(previous.session)
      return false
    }
    // Only a sign-in that landed is a new generation: a rolled-back one left
    // the session as it was, and a sign-out waiting on the server must still
    // keep its rotated token and finish. Nothing here suspends, so no renewal
    // or sign-out can observe the writes before the bump.
    generation += 1
    return true
  }

  /// Renews when due and otherwise sleeps until the next renewal is, until
  /// cancelled. The shell starts it once at launch. The default clock keeps
  /// counting while the Mac sleeps, so a renewal that fell due during sleep
  /// runs on wake.
  public func runRenewal<C: Clock<Duration>>(clock: C = ContinuousClock()) async {
    while !Task.isCancelled {
      // One read of the item per pass, and a second only after a renewal
      // rewrote it. A session item that was unreadable at launch shows as
      // signed out (and dictates to production) until something re-reads it.
      let load = store.load
      updateStatus(from: load)
      let renewed = await renewIfDue(load: load)
      let next = nextRenewalCheck(for: renewed ? store.load : load)
      do { try await clock.sleep(for: .seconds(next)) } catch { return }
    }
  }

  /// Seconds until `runRenewal` should look again: until the session's
  /// renewal is due, within the shortest and longest sleep. Signed out, or a
  /// build that can't renew, the longest; unreadable, `unreadableSessionRecheck`.
  /// `load` is a read of the item the caller already made; nil reads it now.
  func nextRenewalCheck(for load: SignInStore.Load? = nil) -> TimeInterval {
    guard client != nil else { return Self.longestRenewalSleep }
    let session: SignInSession
    switch load ?? store.load {
    case .session(let stored): session = stored
    case .none: return Self.longestRenewalSleep
    case .unavailable: return Self.unreadableSessionRecheck
    }
    let untilDue = session.renewalDue.timeIntervalSince(now())
    return min(max(untilDue, Self.shortestRenewalSleep), Self.longestRenewalSleep)
  }

  /// Dictation refused the stored key (expired early, deleted by an admin, a
  /// revoked connection). Renews at once rather than when due, so the next
  /// dictation has a working key, or the account notices the connection is
  /// over. At most once per `rejectedKeyRenewalSpacing`; nothing to do for a
  /// pasted key.
  public func keyWasRejected() async {
    let now = now()
    if let lastForcedRenewal, now.timeIntervalSince(lastForcedRenewal) < Self.rejectedKeyRenewalSpacing {
      return
    }
    let load = store.load
    guard !signingOut, load.session != nil else { return }
    lastForcedRenewal = now
    await renewIfDue(force: true, load: load)
  }

  /// Refreshes and re-exchanges when `SignInSession.isRenewalDue` says so. A
  /// refused refresh or exchange means the connection is over (revoked from the
  /// dashboard, the member removed, the refresh token lapsed), so the key and
  /// session go and the row offers sign-in again. An unreachable server, or an
  /// unreadable session item, changes nothing; the next check tries again.
  /// `load` is a read of the item the caller already made; nil reads it now.
  /// Returns whether a renewal ran, so `runRenewal` knows its read is stale.
  @discardableResult
  func renewIfDue(load: SignInStore.Load? = nil) async -> Bool {
    await renewIfDue(force: false, load: load ?? store.load)
  }

  /// Whether a renewal ran (this one, or one already in flight), so the
  /// caller knows `load` is stale.
  @discardableResult
  private func renewIfDue(force: Bool, load: SignInStore.Load) async -> Bool {
    guard !signingOut else { return false }
    if let renewal {
      await renewal.value
      return true
    }
    guard let session = load.session,
      force || session.isRenewalDue(now: now(), hasKey: apiKey.current != nil)
    else { return false }
    let task = Task { await renew(session) }
    renewal = task
    await task.value
    renewal = nil
    return true
  }

  /// Ends the connection server-side, then forgets it here. Returns the failure
  /// to show, with everything left in place, when the server couldn't confirm:
  /// the connection is still live and its key still works, so claiming a
  /// sign-out would be wrong. A refresh token the server already refuses means
  /// the connection is already over, which counts as signed out. Nil on success.
  public func signOut() async -> APIKeySubmission.FailureReport? {
    // A second click while the first is still talking to the server: that one
    // reports.
    guard !signingOut else { return nil }
    signingOut = true
    defer { signingOut = false }
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
    let started = generation
    do throws(OAuthClient.Failure) {
      // The rotated token is kept before the revoke: one that fails must leave
      // a token that still works.
      let (tokens, _) = try await refresh(session, with: client, generation: started)
      try await client.revoke(accessToken: tokens.accessToken)
    } catch .rejected {
      // Nothing left server-side to end.
    } catch {
      return .inline(message: Self.signOutUnconfirmedMessage)
    }
    // A sign-in that completed while this waited on the server is the user's
    // newer choice; it stays.
    if generation == started { forget() }
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

  /// Refreshes `session`'s access token and stores a rotated refresh token
  /// before anything else can fail: the old one is dead, and presenting it
  /// again reads as reuse, which ends the grant. The session comes back nil,
  /// with nothing written, when a sign-in, sign-out or reset replaced it
  /// while the refresh was on the network (`generation` moved past `started`).
  private func refresh(
    _ session: SignInSession, with client: OAuthClient, generation started: Int
  ) async throws(OAuthClient.Failure) -> (OAuthClient.Tokens, SignInSession?) {
    let tokens = try await client.refresh(session.refreshToken)
    guard generation == started else { return (tokens, nil) }
    var session = session
    if let rotated = tokens.refreshToken { session.refreshToken = rotated }
    session.email = tokens.email ?? session.email
    store.save(session)
    return (tokens, session)
  }

  private func renew(_ session: SignInSession) async {
    guard let client else { return }
    let started = generation
    do throws(OAuthClient.Failure) {
      let (tokens, refreshed) = try await refresh(session, with: client, generation: started)
      guard var session = refreshed else { return }
      let key = try await client.apiKey(accessToken: tokens.accessToken)
      guard generation == started else { return }
      session.keyExpiresAt = key.expiresAt
      session.keyRotatesAt = key.rotatesAt
      session.renewedAt = now()
      session.deferRenewalIfStillDue(now: session.renewedAt)
      // A key the Keychain refused isn't in place, so the stored dates must stay
      // the old key's: the session stays due and the next check tries again.
      if apiKey.current != key.apiKey, !apiKey.save(key.apiKey) {
        Self.log.error("renewal couldn't store the connection's new key")
        return
      }
      store.save(session)
      status = .signedIn(email: session.email)
    } catch .unreachable {
      return
    } catch {
      if generation == started { forget() }
    }
  }
}
