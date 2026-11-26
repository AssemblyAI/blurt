import Testing

/// Runs each test it covers against its own `ScratchSuite`, torn down after
/// the test whether it passes or throws: `@Test(.scratchSuite)`, or
/// `@Suite(.scratchSuite)` when every test in a suite needs one.
///
/// Recursive on purpose: on a suite, Swift Testing then provides the scope for
/// each test case inside it rather than once around the whole suite, so no two
/// tests ever share a scratch App Group.
struct ScratchSuiteTrait: TestTrait, SuiteTrait, TestScoping {
  var isRecursive: Bool { true }

  func provideScope(
    for _: Test,
    testCase _: Test.Case?,
    performing function: @Sendable () async throws -> Void
  ) async throws {
    let suite = await MainActor.run { ScratchSuite() }
    do {
      try await function()
    } catch {
      await MainActor.run { suite.tearDown() }
      throw error
    }
    await MainActor.run { suite.tearDown() }
  }
}

extension Trait where Self == ScratchSuiteTrait {
  /// A fresh scratch App Group (`ScratchSuite`) around each test.
  static var scratchSuite: Self { Self() }
}
