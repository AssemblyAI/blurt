import Foundation

@testable import BlurtEngine

actor StubMicCapture: MicCaptureProtocol {
  var startCalls = 0
  var stopCalls = 0
  // Comfortably above `SyncSTTLimits.minSamples` so the default press→release
  // flow clears the too-short guard and reaches transcribe, tracking the engine
  // rule so a raised floor can't silently start dropping the canned audio.
  var samplesToReturn: [Float] = Array(repeating: 0, count: SyncSTTLimits.minSamples * 2)
  var startError: (any Error & Sendable)?
  var stopError: (any Error & Sendable)?

  // Actor-isolated methods satisfy these `async` protocol requirements directly,
  // so no `nonisolated` + hop-back-onto-self dance is needed.
  func start() async throws {
    startCalls += 1
    if let startError { throw startError }
  }
  func stop() async throws -> [Float] {
    stopCalls += 1
    if let stopError { throw stopError }
    return samplesToReturn
  }
  func setSamples(_ samples: [Float]) { samplesToReturn = samples }
  func setStartError(_ error: (any Error & Sendable)?) { startError = error }
  func setStopError(_ error: (any Error & Sendable)?) { stopError = error }
}
