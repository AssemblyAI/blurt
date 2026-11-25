public import AssemblyAI
public import Foundation
public import Observation
import os

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
@preconcurrency
@MainActor
@Observable
public final class AssemblyAIAccount {
  private static let log = HostIdentity.current.logger("Account")

  static let signOutUnconfirmedMessage =
    "AssemblyAI couldn’t confirm the sign-out, so Blurt is still connected. Check your connection and try again."
  static let keychainUnreadableMessage =
    "Blurt couldn’t read your sign-in from the macOS Keychain. Check Keychain access and try again."

  /// Whether this build has a Connected App configured. Builds without one
  /// (a dev build with no local sign-in config) show only the paste-a-key path.
  public var isAvailable: Bool { configuration != nil }
  /// Whether this Mac holds a sign-in, and as whom; the account row reads it.
  public internal(set) var status: Status {
    didSet { syncDictationOrigin() }
  }

  /// The dictation host for the current sign-in, for the transcriber. Set to
  /// `dictationHost` while signed in, nil otherwise.
  nonisolated public let dictationOrigin = DictationOrigin()

  // Internal rather than private where `AssemblyAIAccount+SignOut.swift` reads
  // or writes one: `private` is file-scoped.
  @ObservationIgnored private let configuration: OAuthConfiguration?
  /// Where this sign-in's keys dictate; nil means production.
  @ObservationIgnored private let dictationHost: URL?
  @ObservationIgnored let apiKey: APIKeyModel
  @ObservationIgnored let store: SignInStore
  @ObservationIgnored let client: OAuthClient?
  @ObservationIgnored private let now: @Sendable () -> Date
  /// The renewal in flight, which `signOut()` waits out: the renewal may have
  /// rotated the refresh token, and refreshing with the old one would read as
  /// "already over".
  @ObservationIgnored private(set) var renewal: Task<Void, Never>?
  /// While `signOut()` is talking to the server, no renewal may start: it
  /// would present the same refresh token the sign-out is about to rotate,
  /// which reads as reuse and can end the grant mid-sign-out.
  @ObservationIgnored var signingOut = false
  /// When a rejected key last forced a renewal (`keyWasRejected`).
  @ObservationIgnored private var lastForcedRenewal: Date?
  /// Bumped whenever the stored session is replaced or dropped (a sign-in, a
  /// sign-out, a reset). A renewal suspends twice on the network; one that wakes
  /// to a different generation writes nothing, or it would bring back a session
  /// the user just ended.
  @ObservationIgnored var generation = 0

  /// The session storage, for the install reset's sweep (the in-memory store
  /// under UI testing). `refreshStatus()` catches `status` up afterwards.
  public var storage: SignInStore { store }

  /// An account over `configuration`'s Connected App (nil: sign-in isn't
  /// available), storing the connection's key in `apiKey` and the session in
  /// `store`. `transport` and `now` are the network and clock, for tests.
  @preconcurrency
  public init(
    configuration: OAuthConfiguration?,
    apiKey: APIKeyModel,
    dictationHost: URL? = nil,
    store: SignInStore = .production,
    transport: any HTTPTransport = URLSession.shared,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.configuration = configuration
    self.dictationHost = dictationHost
    self.apiKey = apiKey
    self.store = store
    self.client = configuration.map { connectedApp in
      OAuthClient(configuration: connectedApp, transport: transport, userAgent: UserAgent.current)
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

  /// Re-reads the session item and updates `status`, leaving it alone when the
  /// item can't be read. Called when the account UI appears, like
  /// `APIKeyModel.refreshStatus()`.
  public func refreshStatus() {
    updateStatus(from: store.load)
  }

  private func updateStatus(from load: SignInStore.Load) {
    let read: Status
    switch load {
    case .session(let session):
      read = .signedIn(email: session.email)

    case .empty:
      read = .signedOut
      // A session dropped outside the account — the install reset sweeps the
      // storage itself rather than calling `forget()` — is a new generation
      // too, or a renewal parked on the network writes it back.
      if case .signedIn = status { generation += 1 }

    case .unavailable:
      return
    }
    // The key sits in the same Keychain, so a session item that reads again
    // means the key likely does too. Without this, a Mac locked at launch
    // shows "Signed in as …" once it unlocks while `hasAPIKey` stays false,
    // and the wizard keeps the user in onboarding with no hotkey.
    apiKey.refreshStatus()
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
    guard let client else {
      return .failed(.unavailable)
    }
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
        refreshToken: refreshToken,
        email: tokens.email,
        keyExpiresAt: key.expiresAt,
        renewedAt: now(),
        keyRotatesAt: key.rotatesAt
      )
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
  ///
  /// An item that can't be read is replaced: the user just signed in again on
  /// purpose, and refusing would fail every sign-in for as long as the item
  /// stays unreadable (an ACL prompt denied, an item a differently signed
  /// build wrote), with no way out from the sign-in flow. Its contents can't
  /// be put back if the key is then refused, so that rollback is to nothing:
  /// the grant this sign-in minted is revoked either way, and the unreadable
  /// session renewed nothing this build could use.
  private func storeSignIn(_ session: SignInSession, key: String) -> Bool {
    let previous: SignInSession?
    switch store.load {
    case .session(let stored):
      previous = stored

    case .empty:
      previous = nil

    case .unavailable:
      Self.log.notice("replacing a sign-in session item that can't be read")
      previous = nil
    }
    guard store.save(session) else {
      return false
    }
    guard apiKey.save(key) else {
      store.save(previous)
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
    guard client != nil else {
      return Self.longestRenewalSleep
    }
    let session: SignInSession
    switch load ?? store.load {
    case .session(let stored):
      session = stored

    case .empty:
      return Self.longestRenewalSleep

    case .unavailable:
      return Self.unreadableSessionRecheck
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
    let rejectedAt = now()
    if let lastForcedRenewal, rejectedAt.timeIntervalSince(lastForcedRenewal) < Self.rejectedKeyRenewalSpacing {
      return
    }
    let load = store.load
    guard !signingOut, load.session != nil else {
      return
    }
    lastForcedRenewal = rejectedAt
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
    guard !signingOut else {
      return false
    }
    if let renewal {
      await renewal.value
      return true
    }
    guard let session = load.session,
      force || session.isRenewalDue(now: now(), hasKey: apiKey.current != nil)
    else {
      return false
    }
    let task = Task { await renew(session) }
    renewal = task
    await task.value
    renewal = nil
    return true
  }

  /// Refreshes `session`'s access token and stores a rotated refresh token
  /// before anything else can fail: the old one is dead, and presenting it
  /// again reads as reuse, which ends the grant. The session comes back nil,
  /// with nothing written, when a sign-in, sign-out or reset replaced it
  /// while the refresh was on the network (`generation` moved past `started`).
  func refresh(
    _ session: SignInSession, with client: OAuthClient, generation started: Int
  ) async throws(OAuthClient.Failure) -> (OAuthClient.Tokens, SignInSession?) {
    let tokens = try await client.refresh(session.refreshToken)
    guard generation == started else {
      return (tokens, nil)
    }
    var session = session
    if let rotated = tokens.refreshToken { session.refreshToken = rotated }
    session.email = tokens.email ?? session.email
    store.save(session)
    return (tokens, session)
  }

  private func renew(_ session: SignInSession) async {
    guard let client else {
      return
    }
    let started = generation
    do throws(OAuthClient.Failure) {
      let (tokens, refreshed) = try await refresh(session, with: client, generation: started)
      guard var renewed = refreshed else {
        return
      }
      let key = try await client.apiKey(accessToken: tokens.accessToken)
      guard generation == started else {
        return
      }
      renewed.keyExpiresAt = key.expiresAt
      renewed.keyRotatesAt = key.rotatesAt
      renewed.renewedAt = now()
      renewed.deferRenewalIfStillDue(now: renewed.renewedAt)
      // A key the Keychain refused isn't in place, so the stored dates must stay
      // the old key's: the session stays due and the next check tries again.
      if apiKey.current != key.apiKey, !apiKey.save(key.apiKey) {
        Self.log.error("renewal couldn't store the connection's new key")
        return
      }
      store.save(renewed)
      status = .signedIn(email: renewed.email)
    } catch .unreachable {
      return
    } catch {
      if generation == started { forget() }
    }
  }
}
