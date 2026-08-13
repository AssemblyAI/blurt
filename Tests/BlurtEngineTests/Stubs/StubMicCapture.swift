import Foundation

@testable import BlurtEngine

actor StubMicCapture: MicCaptureProtocol {
  var startCalls = 0
  var stopCalls = 0
  var cancelCaptureCalls = 0
  var pcmToReturn = StubPCM.aboveMinimum
  var startError: (any Error & Sendable)?
  var stopError: (any Error & Sendable)?

  // Actor-isolated methods satisfy these `async` protocol requirements directly,
  // so no `nonisolated` + hop-back-onto-self dance is needed.
  func start() async throws {
    startCalls += 1
    if let startError { throw startError }
  }
  func stop() async throws -> Data {
    stopCalls += 1
    if let stopError { throw stopError }
    return pcmToReturn
  }
  /// Overrides the protocol's stop-and-discard default only to *count* the call,
  /// then delegates to `stop()` so `stopCalls` and `stopError` keep meaning what
  /// they did before the cancel path had its own entry point — the suites that
  /// assert a cancel stopped the mic (and that a failing stop is logged) are
  /// unchanged. `MicCaptureProtocolDefaultsTests` covers the bare default.
  func cancelCapture() async throws {
    cancelCaptureCalls += 1
    _ = try await stop()
  }
  func setPCM(_ pcm: Data) { pcmToReturn = pcm }
  func setStartError(_ error: (any Error & Sendable)?) { startError = error }
  func setStopError(_ error: (any Error & Sendable)?) { stopError = error }
}
