import Foundation
import Security
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// An in-memory key store whose writes can be refused, standing in for a
/// Keychain that won't take the key (locked, an ACL prompt pending).
final class RefusingKeyStore: APIKeyGateway {
  private let inner = InMemoryAPIKeyStore()
  private let refusing = Mutex(false)

  var current: String? { inner.current }
  func refuse(_ refuse: Bool) { refusing.withLock { $0 = refuse } }

  @discardableResult
  func save(_ key: String?) -> Bool {
    guard !refusing.withLock({ $0 }) else { return false }
    return inner.save(key)
  }
}

// What the account does when the Keychain refuses a write, and when a sign-out
// overlaps a renewal or a new sign-in.
extension AssemblyAIAccountTests {
  func account(keyStore: RefusingKeyStore, transport: any HTTPTransport) -> AssemblyAIAccount {
    let clock = clock
    return AssemblyAIAccount(
      configuration: testOAuthConfiguration, apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
      store: sessions, transport: transport, now: { clock.now })
  }

  func signIn(_ account: AssemblyAIAccount) async throws -> SignInOutcome {
    let auth = try #require(account.beginSignIn())
    let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    return await account.completeSignIn(auth, callback: callback)
  }

  @Test("a sign-in whose key the Keychain refuses keeps the earlier sign-in and revokes the new grant")
  func signInKeyRefused() async throws {
    let keys = RefusingKeyStore()
    let account = account(keyStore: keys, transport: server.transport)
    #expect(try await signIn(account) == .signedIn)

    server.state.withLock {
      $0.codeGrantRefreshToken = "rt-new"
      $0.apiKey = "second-key"
    }
    keys.refuse(true)
    #expect(try await signIn(account) == .failed(.keychain))
    #expect(sessions.session?.refreshToken == "rt-1")
    #expect(keys.current == "connection-key")
    #expect(account.status == .signedIn(email: "member@example.com"))
    #expect(server.state.withLock { $0.revokes } == 1)
  }

  @Test("a renewal whose new key the Keychain refuses stays due instead of recording the new key's dates")
  func renewalKeyRefused() async throws {
    let keys = RefusingKeyStore()
    let account = account(keyStore: keys, transport: server.transport)
    #expect(try await signIn(account) == .signedIn)
    let before = try #require(sessions.session)

    server.state.withLock {
      $0.apiKey = "rotated-key"
      $0.expiresAt = "2027-01-01T00:00:00Z"
    }
    keys.refuse(true)
    advanceToRenewal()
    await account.renewIfDue()
    #expect(keys.current == "connection-key")
    let after = try #require(sessions.session)
    // The rotated refresh token is kept; the old key's dates stand.
    #expect(after.refreshToken == "rt-2")
    #expect(after.keyExpiresAt == before.keyExpiresAt)
    #expect(account.nextRenewalCheck() == AssemblyAIAccount.shortestRenewalSleep)
  }

  @Test("an unreadable session item is looked at again soon, and the status catches up once it reads")
  func unreadableSessionRechecked() async throws {
    let box = InMemoryAPIKeyStore()
    let locked = Mutex(true)
    let store = SignInStore(
      read: {
        locked.withLock { $0 } ? .unavailable(errSecInteractionNotAllowed) : box.current.map { .value($0) } ?? .absent
      },
      write: { box.save($0) })
    locked.withLock { $0 = false }
    store.save(
      SignInSession(
        refreshToken: "rt-1", email: "member@example.com", keyExpiresAt: nil, keyRotatesAt: nil,
        renewedAt: clock.now))
    locked.withLock { $0 = true }

    keyStore.save("connection-key")
    let account = AssemblyAIAccount(
      configuration: testOAuthConfiguration, apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
      store: store, transport: server.transport, now: { [clock] in clock.now })
    #expect(account.status == .signedOut)
    #expect(account.nextRenewalCheck() == AssemblyAIAccount.unreadableSessionRecheck)

    locked.withLock { $0 = false }
    let loop = Task { await account.runRenewal(clock: TestClock()) }
    for _ in 0..<50 where account.status == .signedOut { await Task.yield() }
    #expect(account.status == .signedIn(email: "member@example.com"))
    loop.cancel()
    await loop.value
  }

  /// A signed-in account whose sign-out is parked at the token endpoint until
  /// the test releases `gate`.
  private struct ParkedSignOut {
    let account: AssemblyAIAccount
    let gate: Gate
    let signOut: Task<APIKeySubmission.FailureReport?, Never>
  }

  private func signOutParkedOnTheNetwork(keys: RefusingKeyStore) async throws -> ParkedSignOut {
    let gate = Gate()
    let transport = GatedTransport(inner: server.transport, gate: gate)
    let account = account(keyStore: keys, transport: transport)
    #expect(try await signIn(account) == .signedIn)
    transport.armed.withLock { $0 = true }
    let signOut = Task { await account.signOut() }
    await gate.waitUntilEntered()
    return ParkedSignOut(account: account, gate: gate, signOut: signOut)
  }

  @Test("no renewal starts while a sign-out is talking to the server")
  func noRenewalDuringSignOut() async throws {
    let parked = try await signOutParkedOnTheNetwork(keys: RefusingKeyStore())
    defer { parked.gate.allowToFinish() }
    await parked.account.keyWasRejected()
    advanceToRenewal()
    await parked.account.renewIfDue()
    parked.gate.allowToFinish()
    #expect(await parked.signOut.value == nil)
    // Only the sign-out's own refresh reached the server.
    #expect(server.state.withLock { $0.refreshTokensSeen } == ["rt-1"])
    #expect(parked.account.status == .signedOut)
  }

  @Test("a sign-in that lands while a sign-out waits on the server is kept")
  func signInDuringSignOut() async throws {
    let keys = RefusingKeyStore()
    let parked = try await signOutParkedOnTheNetwork(keys: keys)
    defer { parked.gate.allowToFinish() }
    server.state.withLock {
      $0.codeGrantRefreshToken = "rt-new"
      $0.apiKey = "second-key"
    }
    #expect(try await signIn(parked.account) == .signedIn)
    parked.gate.allowToFinish()
    #expect(await parked.signOut.value == nil)
    #expect(parked.account.status == .signedIn(email: "member@example.com"))
    #expect(keys.current == "second-key")
    #expect(sessions.session?.refreshToken == "rt-new")
  }

  @Test("a sign-in that fails while a sign-out waits on the server doesn't stop the sign-out")
  func failedSignInDuringSignOut() async throws {
    let keys = RefusingKeyStore()
    let parked = try await signOutParkedOnTheNetwork(keys: keys)
    defer { parked.gate.allowToFinish() }
    keys.refuse(true)
    #expect(try await signIn(parked.account) == .failed(.keychain))
    keys.refuse(false)
    parked.gate.allowToFinish()
    #expect(await parked.signOut.value == nil)
    #expect(parked.account.status == .signedOut)
    #expect(sessions.session == nil)
  }
}
