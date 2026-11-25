import Foundation
import Security
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

@Suite("Sign-in session")
struct SignInSessionTests {
  private let start = Date(timeIntervalSince1970: 1_790_000_000)

  @Test("renewal is due two days before the key expires, or with no key stored, and not daily")
  func renewalDue() {
    let expires = start.addingTimeInterval(14 * 86_400)
    let session = SignInSession(refreshToken: "rt", email: nil, keyExpiresAt: expires, renewedAt: start)
    #expect(session.renewalDue == expires.addingTimeInterval(-SignInSession.expiryMargin))
    #expect(!session.isRenewalDue(now: start.addingTimeInterval(86_400), hasKey: true))
    #expect(!session.isRenewalDue(now: start.addingTimeInterval(11 * 86_400), hasKey: true))
    #expect(session.isRenewalDue(now: start.addingTimeInterval(12 * 86_400), hasKey: true))
    #expect(session.isRenewalDue(now: start.addingTimeInterval(3_600), hasKey: false))
  }

  @Test("the server's rotation time wins over the expiry margin")
  func rotatesAtWins() {
    let rotates = start.addingTimeInterval(10 * 86_400)
    let session = SignInSession(
      refreshToken: "rt",
      email: nil,
      keyExpiresAt: start.addingTimeInterval(14 * 86_400),
      renewedAt: start,
      keyRotatesAt: rotates
    )
    #expect(session.renewalDue == rotates)
  }

  @Test("a session saved before keyRotatesAt existed still reads")
  func oldSessionDecodes() throws {
    let json = #"{"refreshToken":"rt","keyExpiresAt":"2026-11-01T00:00:00Z","renewedAt":"2026-10-01T00:00:00Z"}"#
    let store = SignInStore(read: { .value(json) }, write: { _ in true })
    let session = try #require(store.session)
    #expect(session.keyRotatesAt == nil)
    #expect(session.renewalDue == Date(timeIntervalSince1970: 1_793_491_200 - SignInSession.expiryMargin))
  }

  @Test("an exchange that didn't say when the key expires renews a day after the last renewal")
  func unknownExpiry() {
    let session = SignInSession(refreshToken: "rt", email: nil, keyExpiresAt: nil, renewedAt: start)
    #expect(session.renewalDue == start.addingTimeInterval(SignInSession.unknownExpiryInterval))
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
    #expect(garbage.load == .empty)
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

// The renewal races: a sign-out or a forget landing while a renewal is parked
// on the network must win.
extension AssemblyAIAccountTests {
  /// A signed-in account whose renewal is parked at the token endpoint until
  /// the test releases `gate`.
  private struct ParkedRenewal {
    let account: AssemblyAIAccount
    let gate: Gate
    let renewal: Task<Void, Never>
  }

  @Test("a sign-out during a renewal wins: the renewal wakes and writes nothing back")
  func signOutDuringRenewal() async throws {
    let parked = try await renewalParkedOnTheNetwork()
    let (account, gate, renewal) = (parked.account, parked.gate, parked.renewal)
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

  private func renewalParkedOnTheNetwork() async throws -> ParkedRenewal {
    let gate = Gate()
    let gated = GatedTransport(inner: server.transport, gate: gate)
    let clock = clock
    let account = AssemblyAIAccount(
      configuration: testOAuthConfiguration,
      apiKey: APIKeyModel(keyStore: keyStore) { _ in .valid },
      store: sessions,
      transport: gated
    ) { clock.now }
    let auth = try #require(account.beginSignIn())
    let callback = try #require(URL(string: "com.assemblyai.blurt://oauth/callback?code=c&state=\(auth.state)"))
    #expect(await account.completeSignIn(auth, callback: callback) == .signedIn)

    advanceToRenewal()
    gated.armed.withLock { $0 = true }
    let renewal = Task { _ = await account.renewIfDue() }
    await gate.waitUntilEntered()
    return ParkedRenewal(account: account, gate: gate, renewal: renewal)
  }

  @Test("a forget during a renewal (the reset, an ended connection) also wins")
  func forgetDuringRenewal() async throws {
    let parked = try await renewalParkedOnTheNetwork()
    let (account, gate, renewal) = (parked.account, parked.gate, parked.renewal)
    account.forget()
    gate.allowToFinish()
    await renewal.value
    #expect(account.status == .signedOut)
    #expect(sessions.session == nil)
  }
}
