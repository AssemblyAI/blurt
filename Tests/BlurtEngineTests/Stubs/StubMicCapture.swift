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

  nonisolated func start() async throws {
    await incStart()
    if let e = await self.startError { throw e }
  }
  nonisolated func stop() async throws -> [Float] {
    await incStop()
    if let e = await self.stopError { throw e }
    return await samplesToReturn
  }
  private func incStart() { startCalls += 1 }
  private func incStop() { stopCalls += 1 }
  func setSamples(_ samples: [Float]) { samplesToReturn = samples }
  func setStartError(_ error: (any Error & Sendable)?) { startError = error }
  func setStopError(_ error: (any Error & Sendable)?) { stopError = error }
}
