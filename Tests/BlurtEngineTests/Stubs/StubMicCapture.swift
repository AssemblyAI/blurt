import Foundation

@testable import BlurtEngine

actor StubMicCapture: MicCaptureProtocol {
  var startCalls = 0
  var stopCalls = 0
  // Above `SyncSTTLimits.minSamples` (16 kHz × 0.1 s = 1600) so the default
  // press→release flow clears the too-short guard and reaches transcribe.
  var samplesToReturn: [Float] = Array(repeating: 0, count: 1600)
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
