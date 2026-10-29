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

/// Parks the first token request after `hold()` until `release()`, so a test
/// can act while a sign-out waits on the server. Later requests pass straight
/// through, so a request the code under test shouldn't make shows up at the
/// server rather than hanging the test.
final class HoldingTransport: HTTPTransport, Sendable {
  private struct State {
    var armed = false
    var parked: CheckedContinuation<Void, Never>?
  }

  private let inner: FakeHTTPTransport
  private let state = Mutex(State())

  init(_ inner: FakeHTTPTransport) { self.inner = inner }

  func hold() { state.withLock { $0.armed = true } }
  var isParked: Bool { state.withLock { $0.parked != nil } }

  func release() {
    let parked = state.withLock { state -> CheckedContinuation<Void, Never>? in
      defer { state.parked = nil }
      return state.parked
    }
    parked?.resume()
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    if request.url == testOAuthConfiguration.tokenURL {
      await withCheckedContinuation { continuation in
        let park = state.withLock { state -> Bool in
          guard state.armed else { return false }
          state.armed = false
          state.parked = continuation
          return true
        }
        if !park { continuation.resume() }
      }
    }
    return try await inner.data(for: request)
  }

  func upload(
    for request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse) {
    try await inner.upload(for: request, streaming: body, delegate: delegate)
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

  @Test("no renewal starts while a sign-out is talking to the server")
  func noRenewalDuringSignOut() async throws {
    let transport = HoldingTransport(server.transport)
    let account = account(keyStore: RefusingKeyStore(), transport: transport)
    #expect(try await signIn(account) == .signedIn)

    transport.hold()
    defer { transport.release() }
    let signOut = Task { await account.signOut() }
    try await waitUntilParked(transport)
    await account.keyWasRejected()
    advanceToRenewal()
    await account.renewIfDue()
    transport.release()
    #expect(await signOut.value == nil)
    // Only the sign-out's own refresh reached the server.
    #expect(server.state.withLock { $0.refreshTokensSeen } == ["rt-1"])
    #expect(account.status == .signedOut)
  }

  @Test("a sign-in that lands while a sign-out waits on the server is kept")
  func signInDuringSignOut() async throws {
    let transport = HoldingTransport(server.transport)
    let keys = RefusingKeyStore()
    let account = account(keyStore: keys, transport: transport)
    #expect(try await signIn(account) == .signedIn)

    transport.hold()
    defer { transport.release() }
    let signOut = Task { await account.signOut() }
    try await waitUntilParked(transport)
    server.state.withLock {
      $0.codeGrantRefreshToken = "rt-new"
      $0.apiKey = "second-key"
    }
    #expect(try await signIn(account) == .signedIn)
    transport.release()
    #expect(await signOut.value == nil)
    #expect(account.status == .signedIn(email: "member@example.com"))
    #expect(keys.current == "second-key")
    #expect(sessions.session?.refreshToken == "rt-new")
  }

  @Test("a sign-in that fails while a sign-out waits on the server doesn't stop the sign-out")
  func failedSignInDuringSignOut() async throws {
    let transport = HoldingTransport(server.transport)
    let keys = RefusingKeyStore()
    let account = account(keyStore: keys, transport: transport)
    #expect(try await signIn(account) == .signedIn)

    transport.hold()
    defer { transport.release() }
    let signOut = Task { await account.signOut() }
    try await waitUntilParked(transport)
    keys.refuse(true)
    #expect(try await signIn(account) == .failed(.keychain))
    keys.refuse(false)
    transport.release()
    #expect(await signOut.value == nil)
    #expect(account.status == .signedOut)
    #expect(sessions.session == nil)
  }

  private func waitUntilParked(_ transport: HoldingTransport) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !transport.isParked, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(transport.isParked)
  }
}
