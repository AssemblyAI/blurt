import Foundation

@testable import BlurtEngine

actor StubMicCapture: MicCaptureProtocol {
  var startCalls = 0
  var stopCalls = 0
  // Comfortably above `SyncSTTLimits.minPCMBytes` so the default press→release
  // flow clears the too-short guard and reaches transcribe, tracking the engine
  // rule so a raised floor can't silently start dropping the canned audio.
  var pcmToReturn = Data(count: SyncSTTLimits.minPCMBytes * 2)
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
  func setPCM(_ pcm: Data) { pcmToReturn = pcm }
  func setStartError(_ error: (any Error & Sendable)?) { startError = error }
  func setStopError(_ error: (any Error & Sendable)?) { stopError = error }
}
