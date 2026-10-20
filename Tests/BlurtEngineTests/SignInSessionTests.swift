import Foundation
import Security
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// Parks token-endpoint requests on `gate` while `armed`, to hold a renewal
/// mid-flight; everything else goes straight to `inner`.
private final class GatedTransport: HTTPTransport, Sendable {
  let inner: FakeHTTPTransport
  let gate: Gate
  let armed = Mutex(false)

  init(inner: FakeHTTPTransport, gate: Gate) {
    self.inner = inner
    self.gate = gate
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let hold = armed.withLock { armed in
      defer { armed = false }
      return armed && request.url == testOAuthConfiguration.tokenURL
    }
    if hold { await gate.enter() }
    return try await inner.data(for: request)
  }

  func upload(
    for request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse) {
    try await inner.upload(for: request, streaming: body, delegate: delegate)
  }
}

// The renewal races: a sign-out or a forget landing while a renewal is parked
// on the network must win.
extension AssemblyAIAccountTests {
  @Test("a sign-out during a renewal wins: the renewal wakes and writes nothing back")
  func signOutDuringRenewal() async throws {
    let gate = Gate()
    let gated = GatedTransport(inner: server.transport, gate: gate)
    let clock = clock
    let account = AssemblyAIAccount(
      configuration: testOAuthConfiguration, apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
      store: sessions, transport: gated, now: { clock.now })
    let auth = try #require(account.beginSignIn())
    let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    #expect(await account.completeSignIn(auth, callback: callback) == .signedIn)

    clock.advance(SignInSession.renewalInterval)
    gated.armed.withLock { $0 = true }
    let renewal = Task { await account.renewIfDue() }
    await gate.waitUntilEntered()
    let signOut = Task { await account.signOut() }
    gate.allowToFinish()
    await renewal.value
    #expect(await signOut.value == nil)

    #expect(account.status == .signedOut)
    #expect(sessions.session == nil)
    #expect(keyStore.current == nil)
    // Sign-out waited for the renewal and refreshed with the rotated token.
    #expect(server.state.withLock { $0.refreshTokensSeen } == ["rt-1", "rt-2"])
  }

  @Test("a forget during a renewal (the reset, an ended connection) also wins")
  func forgetDuringRenewal() async throws {
    let gate = Gate()
    let gated = GatedTransport(inner: server.transport, gate: gate)
    let clock = clock
    let account = AssemblyAIAccount(
      configuration: testOAuthConfiguration, apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
      store: sessions, transport: gated, now: { clock.now })
    let auth = try #require(account.beginSignIn())
    let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    _ = await account.completeSignIn(auth, callback: callback)

    clock.advance(SignInSession.renewalInterval)
    gated.armed.withLock { $0 = true }
    let renewal = Task { await account.renewIfDue() }
    await gate.waitUntilEntered()
    account.forget()
    gate.allowToFinish()
    await renewal.value
    #expect(account.status == .signedOut)
    #expect(sessions.session == nil)
  }
}

@Suite("Sign-in session")
struct SignInSessionTests {
  private let start = Date(timeIntervalSince1970: 1_790_000_000)

  @Test("renewal is due after a day, near the key's expiry, or with no key stored")
  func renewalDue() {
    let session = SignInSession(
      refreshToken: "rt", email: nil, keyExpiresAt: start.addingTimeInterval(30 * 86_400), renewedAt: start)
    #expect(!session.isRenewalDue(now: start.addingTimeInterval(3_600), hasKey: true))
    #expect(session.isRenewalDue(now: start.addingTimeInterval(3_600), hasKey: false))
    #expect(session.isRenewalDue(now: start.addingTimeInterval(SignInSession.renewalInterval), hasKey: true))

    let expiring = SignInSession(
      refreshToken: "rt", email: nil, keyExpiresAt: start.addingTimeInterval(86_400), renewedAt: start)
    #expect(expiring.isRenewalDue(now: start.addingTimeInterval(60), hasKey: true))
  }

  @Test("the store round-trips a session and deletes on nil; unreadable JSON reads as none")
  func store() {
    let store = SignInStore.inMemory()
    let session = SignInSession(refreshToken: "rt", email: "a@b.co", keyExpiresAt: start, renewedAt: start)
    #expect(store.save(session))
    #expect(store.session == session)
    #expect(store.save(nil))
    #expect(store.session == nil)

    let garbage = SignInStore(read: { .value("{not json") }, write: { _ in true })
    #expect(garbage.load == .none)
    let locked = SignInStore(read: { .unavailable(errSecInteractionNotAllowed) }, write: { _ in true })
    #expect(locked.load == .unavailable)
  }

  @Test("the account row names the member when the ID token did")
  func statusText() {
    #expect(AssemblyAIAccount.Status.signedIn(email: "a@b.co").statusText == "Signed in as a@b.co")
    #expect(AssemblyAIAccount.Status.signedIn(email: nil).statusText == "Signed in")
    #expect(AssemblyAIAccount.Status.signedOut.statusText == nil)
  }

  @Test("failure wording: the server's reason when given, a generic line otherwise")
  func failureWording() {
    #expect(SignInFailure.forbidden("missing aai:api").message.contains("missing aai:api"))
    #expect(SignInFailure.forbidden(nil).message.contains("admin"))
    #expect(
      SignInFailure.keychain.failureReport
        == .alert(title: "Couldn’t Save Your Sign-In", message: SignInFailure.keychain.message))
    for failure in [SignInFailure.unavailable, .consent, .rejected, .server, .forbidden(nil)] {
      #expect(failure.failureReport == .inline(message: failure.message))
      #expect(!failure.message.isEmpty)
    }
  }
}

@Suite("OAuth configuration from Info.plist")
struct OAuthConfigurationInfoTests {
  private let info: [String: Any] = [
    OAuthConfiguration.InfoKey.clientID: "client",
    OAuthConfiguration.InfoKey.tokenURL: "https://auth.example.com/v1/oauth2/token",
    OAuthConfiguration.InfoKey.authorizeURL: "https://dashboard.example.com/dashboard/oauth/authorize",
    OAuthConfiguration.InfoKey.apiOrigin: "https://www.example.com",
  ]

  @Test("all four keys set: the consent page as given, the key routes under the API origin")
  func configured() throws {
    let config = try #require(OAuthConfiguration.blurt(infoDictionary: info))
    #expect(config.clientID == "client")
    #expect(config.authorizeURL.absoluteString == "https://dashboard.example.com/dashboard/oauth/authorize")
    #expect(config.apiKeyURL.absoluteString == "https://www.example.com/api/v2/oauth/api-key")
    #expect(config.revokeURL.absoluteString == "https://www.example.com/api/v2/oauth/api-key/revoke")
    #expect(config.redirectURI.absoluteString == "com.assemblyai.blurt://oauth/callback")
  }

  @Test("a missing, blank or non-https value turns sign-in off")
  func unconfigured() {
    #expect(OAuthConfiguration.blurt(infoDictionary: [:]) == nil)
    for key in info.keys {
      var blank = info
      blank[key] = " "
      #expect(OAuthConfiguration.blurt(infoDictionary: blank) == nil)
    }
    for key in info.keys where key != OAuthConfiguration.InfoKey.clientID {
      var http = info
      http[key] = "http://www.example.com"
      #expect(OAuthConfiguration.blurt(infoDictionary: http) == nil)
    }
  }

  @Test("plain http is allowed to this machine only, for a dev build on a local dashboard or site")
  func loopback() {
    for host in ["localhost:3000", "127.0.0.1:3000", "[::1]:3000"] {
      var local = info
      local[OAuthConfiguration.InfoKey.authorizeURL] = "http://\(host)/dashboard/oauth/authorize"
      #expect(OAuthConfiguration.blurt(infoDictionary: local) != nil, "\(host)")
    }
    var lookalike = info
    lookalike[OAuthConfiguration.InfoKey.apiOrigin] = "http://localhost.example.com"
    #expect(OAuthConfiguration.blurt(infoDictionary: lookalike) == nil)
  }
}

@Suite("Credential rows")
struct CredentialRowsTests {
  @Test("signed out with sign-in configured: account row first and filled, key row below")
  func signedOutWithSignIn() {
    let rows = CredentialRows.resolve(isKeyStored: false, isSignInAvailable: true, status: .signedOut)
    #expect(rows == CredentialRows(showsAccountRow: true, showsKeyRow: true, primary: .signIn))
  }

  @Test("no sign-in configured: just the key row, Connect filled until a key is stored")
  func withoutSignIn() {
    #expect(
      CredentialRows.resolve(isKeyStored: false, isSignInAvailable: false, status: .signedOut)
        == CredentialRows(showsAccountRow: false, showsKeyRow: true, primary: .connect))
    #expect(
      CredentialRows.resolve(isKeyStored: true, isSignInAvailable: false, status: .signedOut).primary == nil)
  }

  @Test("signed in: the account row replaces the key row, even where sign-in isn't configured")
  func signedIn() {
    for available in [true, false] {
      #expect(
        CredentialRows.resolve(isKeyStored: true, isSignInAvailable: available, status: .signedIn(email: nil))
          == CredentialRows(showsAccountRow: true, showsKeyRow: false, primary: nil))
    }
  }
}
