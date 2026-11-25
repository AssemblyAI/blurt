import Foundation
import Security
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

@Suite("AssemblyAI account (sign in with AssemblyAI)")
@MainActor
struct AssemblyAIAccountTests {
  let server = SignInServer()
  let clock = SignInTestClock()
  let keyStore = InMemoryAPIKeyStore()
  let sessions = SignInStore.inMemory()

  func account(configured: Bool = true) -> AssemblyAIAccount {
    let testClock = clock
    return AssemblyAIAccount(
      configuration: configured ? testOAuthConfiguration : nil,
      apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
      store: sessions,
      transport: server.transport
    ) { testClock.now }
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
      let freshServer = SignInServer()
      let freshKeys = InMemoryAPIKeyStore()
      let freshSessions = SignInStore.inMemory()
      let testClock = clock
      let account = AssemblyAIAccount(
        configuration: testOAuthConfiguration,
        apiKey: APIKeyModel(keyStore: freshKeys) { _ in .valid },
        store: freshSessions,
        transport: freshServer.transport
      ) { testClock.now }
      let auth = try #require(account.beginSignIn())
      let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
      _ = await account.completeSignIn(auth, callback: callback)

      freshServer.state.withLock { state in
        if refuseRefresh { state.tokenStatus = 400 } else { state.exchangeStatus = 401 }
      }
      freshKeys.save(nil)  // no key stored makes renewal due right away
      await account.renewIfDue()
      #expect(account.status == .signedOut)
      #expect(freshSessions.session == nil)
      #expect(freshKeys.current == nil)
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
    // The refresh before the revoke rotated the token, and the rotated one was
    // kept: the old one is dead, and sending it again would end the grant.
    #expect(sessions.session?.refreshToken == "rt-2")

    // So the retry refreshes with the token that still works.
    server.state.withLock { $0.revokeStatus = 204 }
    #expect(await account.signOut() == nil)
    #expect(server.state.withLock { $0.refreshTokensSeen } == ["rt-1", "rt-2"])
    #expect(account.status == .signedOut)
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
      configuration: testOAuthConfiguration,
      apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
      store: locked,
      transport: server.transport
    )
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
    guard let due = sessions.session?.renewalDue else {
      return
    }
    clock.advance(max(0, due.timeIntervalSince(clock.now)))
  }
}

extension SignInStore {
  /// The stored session, or nil when there is none or it can't be read.
  var session: SignInSession? { load.session }
}
