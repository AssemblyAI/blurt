import Foundation
import Security
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// Answers the three sign-in routes from per-route statuses the test sets, and
/// records what was sent.
final class SignInServer: Sendable {
  struct State {
    var tokenStatus = 200
    var exchangeStatus = 200
    var revokeStatus = 204
    var codeGrantRefreshToken: String? = "rt-1"
    var rotatedRefreshToken: String? = "rt-2"
    var apiKey = "connection-key"
    var expiresAt = "2026-11-01T00:00:00Z"
    var rotatesAt: String?
    var refreshTokensSeen: [String] = []
    var exchanges = 0
    var revokes = 0
  }

  let state = Mutex(State())

  var transport: FakeHTTPTransport {
    FakeHTTPTransport { [self] request in
      state.withLock { state in
        switch request.url {
        case testOAuthConfiguration.tokenURL:
          let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
          if let pair = body.split(separator: "&").first(where: { $0.hasPrefix("refresh_token=") }) {
            state.refreshTokensSeen.append(String(pair.dropFirst("refresh_token=".count)))
          }
          guard state.tokenStatus == 200 else { return (state.tokenStatus, json(["error": "invalid_grant"])) }
          var fields = ["access_token": "at", "id_token": unsignedJWT(["email": "member@example.com"])]
          if body.contains("authorization_code") {
            fields["refresh_token"] = state.codeGrantRefreshToken
          } else if let rotated = state.rotatedRefreshToken {
            fields["refresh_token"] = rotated
          }
          return (200, json(fields))
        case testOAuthConfiguration.apiKeyURL:
          state.exchanges += 1
          guard state.exchangeStatus == 200 else { return (state.exchangeStatus, Data()) }
          var body = ["api_key": state.apiKey, "api_key_expires_at": state.expiresAt]
          body["api_key_rotates_at"] = state.rotatesAt
          return (200, json(body))
        case testOAuthConfiguration.revokeURL:
          state.revokes += 1
          return (state.revokeStatus, Data())
        default:
          return (404, Data())
        }
      }
    }
  }
}

/// A clock the test moves.
final class SignInTestClock: Sendable {
  let date = Mutex(Date(timeIntervalSince1970: 1_790_000_000))
  var now: Date { date.withLock { $0 } }
  func advance(_ interval: TimeInterval) { date.withLock { $0 += interval } }
}

@Suite("AssemblyAI account (sign in with AssemblyAI)")
@MainActor
struct AssemblyAIAccountTests {
  let server = SignInServer()
  let clock = SignInTestClock()
  let keyStore = InMemoryAPIKeyStore()
  let sessions = SignInStore.inMemory()

  func account(configured: Bool = true) -> AssemblyAIAccount {
    let clock = clock
    return AssemblyAIAccount(
      configuration: configured ? testOAuthConfiguration : nil,
      apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
      store: sessions,
      transport: server.transport,
      now: { clock.now })
  }

  func signedIn() async throws -> AssemblyAIAccount {
    let account = account()
    let auth = try #require(account.beginSignIn())
    let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    #expect(await account.completeSignIn(auth, callback: callback) == .signedIn)
    return account
  }

  @Test("signing in stores the connection's key where a pasted one goes, plus the session")
  func signIn() async throws {
    let account = try await signedIn()
    #expect(account.status == .signedIn(email: "member@example.com"))
    #expect(keyStore.current == "connection-key")
    let session = try #require(sessions.session)
    #expect(session.refreshToken == "rt-1")
    #expect(session.renewedAt == clock.now)
    #expect(session.keyExpiresAt == Date(timeIntervalSince1970: 1_793_491_200))
    // A fresh model over the same stores reads the session back.
    #expect(self.account().status == .signedIn(email: "member@example.com"))
  }

  @Test("a decline is a quiet cancel; a bad redirect is a failure; neither stores anything")
  func signInRefusedAtConsent() async throws {
    keyStore.save("pasted")
    let account = account()
    let auth = try #require(account.beginSignIn())
    let declined = try #require(
      URL(string: "com.assemblyai.blurt://oauth/callback?error=access_denied&state=\(auth.state)"))
    #expect(await account.completeSignIn(auth, callback: declined) == .cancelled)
    let forged = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=forged"))
    #expect(await account.completeSignIn(auth, callback: forged) == .failed(.consent))
    #expect(keyStore.current == "pasted")
    #expect(sessions.session == nil)
    #expect(account.status == .signedOut)
  }

  @Test("a refused exchange fails the sign-in and leaves a pasted key in place")
  func signInExchangeRefused() async throws {
    keyStore.save("pasted")
    server.state.withLock { $0.exchangeStatus = 403 }
    let account = account()
    let auth = try #require(account.beginSignIn())
    let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    #expect(await account.completeSignIn(auth, callback: callback) == .failed(.forbidden(nil)))
    #expect(keyStore.current == "pasted")
    #expect(sessions.session == nil)
  }

  @Test("no refresh token (it couldn't be renewed) or an unreachable token endpoint fails the sign-in")
  func signInTokenFailures() async throws {
    let account = account()
    server.state.withLock { $0.codeGrantRefreshToken = nil }
    var auth = try #require(account.beginSignIn())
    var callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    #expect(await account.completeSignIn(auth, callback: callback) == .failed(.server))
    #expect(server.state.withLock { $0.exchanges } == 0)

    server.state.withLock { $0.tokenStatus = 503 }
    auth = try #require(account.beginSignIn())
    callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    #expect(await account.completeSignIn(auth, callback: callback) == .failed(.server))
    #expect(sessions.session == nil)
  }

  @Test("an unconfigured build offers no sign-in")
  func unavailable() async throws {
    let account = account(configured: false)
    #expect(!account.isAvailable)
    #expect(account.beginSignIn() == nil)
    let auth = OAuthAuthorization(configuration: testOAuthConfiguration)
    let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    #expect(await account.completeSignIn(auth, callback: callback) == .failed(.unavailable))
  }

  @Test("renewal waits until the key nears expiry, then refreshes, keeps the rotated token and any new key")
  func renewal() async throws {
    let account = try await signedIn()
    await account.renewIfDue()
    #expect(server.state.withLock { $0.refreshTokensSeen }.isEmpty)

    advanceToRenewal()
    server.state.withLock { $0.apiKey = "next-key" }
    await account.renewIfDue()
    #expect(server.state.withLock { $0.refreshTokensSeen } == ["rt-1"])
    #expect(keyStore.current == "next-key")
    let session = try #require(sessions.session)
    #expect(session.refreshToken == "rt-2")
    #expect(session.renewedAt == clock.now)
  }

  @Test("a refresh that doesn't rotate keeps the token it has")
  func renewalWithoutRotation() async throws {
    let account = try await signedIn()
    server.state.withLock { $0.rotatedRefreshToken = nil }
    advanceToRenewal()
    await account.renewIfDue()
    #expect(sessions.session?.refreshToken == "rt-1")
  }

  @Test("a refused refresh or exchange ends the connection here: key and session go")
  func renewalRefused() async throws {
    for refuseRefresh in [true, false] {
      let server = SignInServer()
      let keyStore = InMemoryAPIKeyStore()
      let sessions = SignInStore.inMemory()
      let clock = clock
      let account = AssemblyAIAccount(
        configuration: testOAuthConfiguration, apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
        store: sessions, transport: server.transport, now: { clock.now })
      let auth = try #require(account.beginSignIn())
      let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
      _ = await account.completeSignIn(auth, callback: callback)

      server.state.withLock { state in
        if refuseRefresh { state.tokenStatus = 400 } else { state.exchangeStatus = 401 }
      }
      keyStore.save(nil)  // no key stored makes renewal due right away
      await account.renewIfDue()
      #expect(account.status == .signedOut)
      #expect(sessions.session == nil)
      #expect(keyStore.current == nil)
    }
  }

  @Test("an unreachable server during renewal changes nothing")
  func renewalOffline() async throws {
    let account = try await signedIn()
    server.state.withLock { $0.exchangeStatus = 503 }
    advanceToRenewal()
    await account.renewIfDue()
    #expect(account.status == .signedIn(email: "member@example.com"))
    #expect(keyStore.current == "connection-key")
    // The rotated refresh token was still kept: the old one is dead.
    #expect(sessions.session?.refreshToken == "rt-2")
  }

  @Test("sign-out ends the connection server-side, then forgets it here")
  func signOut() async throws {
    let account = try await signedIn()
    #expect(await account.signOut() == nil)
    #expect(server.state.withLock { $0.revokes } == 1)
    #expect(account.status == .signedOut)
    #expect(keyStore.current == nil)
    #expect(sessions.session == nil)
  }

  @Test("sign-out the server couldn't confirm keeps everything, so the user can retry")
  func signOutUnconfirmed() async throws {
    let account = try await signedIn()
    server.state.withLock { $0.revokeStatus = 503 }
    #expect(await account.signOut() == .inline(message: AssemblyAIAccount.signOutUnconfirmedMessage))
    #expect(account.status == .signedIn(email: "member@example.com"))
    #expect(keyStore.current == "connection-key")
  }

  @Test("sign-out with a refresh token the server already refuses is a sign-out")
  func signOutAlreadyEnded() async throws {
    let account = try await signedIn()
    server.state.withLock { $0.tokenStatus = 400 }
    #expect(await account.signOut() == nil)
    #expect(server.state.withLock { $0.revokes } == 0)
    #expect(account.status == .signedOut)
  }

  @Test("sign-out with no session just clears; a build without sign-in still removes an inherited session")
  func signOutEdges() async throws {
    let fresh = account()
    keyStore.save("pasted")
    #expect(await fresh.signOut() == nil)
    #expect(keyStore.current == nil)

    _ = try await signedIn()
    let unconfigured = account(configured: false)
    #expect(unconfigured.status == .signedIn(email: "member@example.com"))
    #expect(await unconfigured.signOut() == nil)
    #expect(unconfigured.status == .signedOut)
    #expect(sessions.session == nil)
    #expect(keyStore.current == nil)
    #expect(server.state.withLock { $0.revokes } == 0)
  }

  @Test("an unreadable session item is neither signed in nor signed out: sign-out refuses, nothing is deleted")
  func unreadableSession() async {
    keyStore.save("connection-key")
    let locked = SignInStore(read: { .unavailable(errSecInteractionNotAllowed) }, write: { _ in true })
    let account = AssemblyAIAccount(
      configuration: testOAuthConfiguration, apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
      store: locked, transport: server.transport)
    #expect(account.status == .signedOut)
    #expect(await account.signOut() == .inline(message: AssemblyAIAccount.keychainUnreadableMessage))
    #expect(keyStore.current == "connection-key")
    await account.renewIfDue()
    #expect(server.state.withLock { $0.refreshTokensSeen }.isEmpty)
  }

  @Test("refreshStatus follows the item, and leaves the status alone while it can't be read")
  func refreshStatus() async throws {
    let account = try await signedIn()
    sessions.save(nil)
    account.refreshStatus()
    #expect(account.status == .signedOut)
  }

  /// Moves the clock to the stored session's renewal date.
  func advanceToRenewal() {
    guard let due = sessions.session?.renewalDue else { return }
    clock.advance(max(0, due.timeIntervalSince(clock.now)))
  }
}

extension SignInStore {
  /// The stored session, or nil when there is none or it can't be read.
  var session: SignInSession? {
    if case .session(let session) = load { return session }
    return nil
  }
}
