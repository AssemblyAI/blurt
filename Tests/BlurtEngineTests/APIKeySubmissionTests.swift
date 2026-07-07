import Testing

@testable import BlurtEngine

/// The validate-then-save flow behind the Save/Update button. The invariant
/// under test: **an unverified key never persists** — storage is written only
/// when AssemblyAI actively accepts the key, and a write that doesn't survive a
/// read-back is reported as `.saveFailed` rather than a silent success.
@Suite("APIKeySubmission")
struct APIKeySubmissionTests {
  /// Gateway whose writes always fail — the Keychain-write-fault branch.
  private struct RejectingKeyStore: APIKeyGateway {
    func get() -> String? { nil }
    @discardableResult func set(_ key: String?) -> Bool { false }
  }

  /// A submission whose validator deterministically returns `result`.
  private func submission(
    store: any APIKeyGateway, result: APIKeyValidator.Result
  ) -> APIKeySubmission {
    APIKeySubmission(keyStore: store) { _ in result }
  }

  @Test("a key AssemblyAI accepts is saved and reported valid")
  func validKeySaves() async {
    let store = InMemoryAPIKeyStore()
    let outcome = await submission(store: store, result: .valid).submit("sk-good")
    #expect(outcome == .valid)
    #expect(store.get() == "sk-good")
  }

  @Test("a rejected key is never persisted")
  func invalidKeyNotSaved() async {
    let store = InMemoryAPIKeyStore()
    let outcome = await submission(store: store, result: .invalid).submit("sk-bad")
    #expect(outcome == .invalid)
    #expect(store.get() == nil)
  }

  @Test("a rejected key never overwrites the previously saved one")
  func invalidKeyKeepsExistingKey() async {
    let store = InMemoryAPIKeyStore()
    store.set("sk-old")
    let outcome = await submission(store: store, result: .invalid).submit("sk-bad")
    #expect(outcome == .invalid)
    #expect(store.get() == "sk-old")
  }

  @Test("an unreachable server never persists the unverified key")
  func unreachableNotSaved() async {
    // The key might be perfectly good — but it wasn't *verified*, so it must
    // not be stored; the user retries once online.
    let store = InMemoryAPIKeyStore()
    let outcome = await submission(store: store, result: .unreachable).submit("sk-maybe")
    #expect(outcome == .unreachable)
    #expect(store.get() == nil)
  }

  @Test("a validated key whose write fails reports saveFailed")
  func failedWriteReportsSaveFailed() async {
    let outcome = await submission(store: RejectingKeyStore(), result: .valid).submit("sk-good")
    #expect(outcome == .saveFailed)
  }

  @Test("save requires the key to be readable back, not just an accepted write")
  func saveVerifiesReadBack() {
    // A whitespace-only key writes "successfully" (the gateway treats it as a
    // delete), but no key is stored afterwards — that's a failed save, not a
    // success that leaves the readiness gate closed with no explanation.
    let store = InMemoryAPIKeyStore()
    let keySubmission = submission(store: store, result: .valid)
    #expect(!keySubmission.save("   "))
    #expect(keySubmission.save("sk-good"))
  }

  @Test("the public convenience init wires the store through to save")
  func productionInitWiresTheStore() {
    // Every other test uses the validate-injecting seam init; the app itself
    // builds `APIKeySubmission(keyStore:)` with the default `APIKeyValidator`.
    // Exercise that production initializer via `save` (no network, so the
    // default validator never fires) to prove it forwards writes to the store
    // it was handed rather than dropping them.
    let store = InMemoryAPIKeyStore()
    let keySubmission = APIKeySubmission(keyStore: store)
    #expect(keySubmission.save("sk-good"))
    #expect(store.get() == "sk-good")
  }
}
