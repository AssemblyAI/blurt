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
    var current: String? { nil }
    @discardableResult func save(_ key: String?) -> Bool { false }
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
    #expect(store.current == "sk-good")
  }

  @Test("a rejected key is never persisted")
  func invalidKeyNotSaved() async {
    let store = InMemoryAPIKeyStore()
    let outcome = await submission(store: store, result: .invalid).submit("sk-bad")
    #expect(outcome == .invalid)
    #expect(store.current == nil)
  }

  @Test("a rejected key never overwrites the previously saved one")
  func invalidKeyKeepsExistingKey() async {
    let store = InMemoryAPIKeyStore()
    store.save("sk-old")
    let outcome = await submission(store: store, result: .invalid).submit("sk-bad")
    #expect(outcome == .invalid)
    #expect(store.current == "sk-old")
  }

  @Test("an unreachable server never persists the unverified key")
  func unreachableNotSaved() async {
    // The key might be perfectly good — but it wasn't *verified*, so it must
    // not be stored; the user retries once online.
    let store = InMemoryAPIKeyStore()
    let outcome = await submission(store: store, result: .unreachable).submit("sk-maybe")
    #expect(outcome == .unreachable)
    #expect(store.current == nil)
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

  @Test("save forwards writes to the store it was handed")
  func saveWiresTheStore() {
    let store = InMemoryAPIKeyStore()
    let keySubmission = submission(store: store, result: .valid)
    #expect(keySubmission.save("sk-good"))
    #expect(store.current == "sk-good")
  }

  // MARK: - Failure reporting
  //
  // Which outcomes are recoverable-inline and which is a genuine fault used to be
  // decided in the settings sheet's `switch`. Owning the classification here is
  // the same move as `PipelinePhase.setupBlocker`: adding an `Outcome` case can't
  // ship with the wrong severity, because that judgement now has a test.

  @Test("a stored key has nothing to report")
  func validReportsNothing() {
    #expect(APIKeySubmission.Outcome.valid.failureReport == nil)
  }

  @Test("a rejected key is inline and recoverable")
  func invalidIsInline() {
    #expect(
      APIKeySubmission.Outcome.invalid.failureReport
        == .inline(message: "AssemblyAI rejected that key. Double-check it and try again."))
  }

  @Test("an unreachable server is inline and recoverable")
  func unreachableIsInline() {
    #expect(
      APIKeySubmission.Outcome.unreachable.failureReport
        == .inline(message: "Couldn't reach AssemblyAI. Check your connection and try again."))
  }

  @Test("a Keychain write fault is an alert, not inline text")
  func saveFailedIsAnAlert() {
    // Retyping the key can't fix a failed Keychain write, so it must not be
    // shown as field text the user is invited to correct.
    let report = APIKeySubmission.Outcome.saveFailed.failureReport
    guard case .some(.alert(let title, let message)) = report else {
      Issue.record("saveFailed must report as an alert, got \(String(describing: report))")
      return
    }
    #expect(title == "Couldn’t Save Your Key")
    #expect(message.contains("Keychain"))
  }

  @Test("every failing outcome reports something the user can read")
  func everyFailureIsReported() {
    // A failure with no report would leave the sheet silently doing nothing.
    for outcome in [APIKeySubmission.Outcome.invalid, .unreachable, .saveFailed] {
      #expect(outcome.failureReport != nil)
    }
  }
}
