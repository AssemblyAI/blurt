import Foundation

@testable import BlurtEngine

/// Mic stub whose `stop()` signals entry and then blocks until the test releases
/// it, so a second `release()`/`cancel()` can be landed deterministically while
/// the first caller is suspended inside `mic.stop()`. Tolerates concurrent
/// `stop()` calls (the regressions under test trigger a second). An injected
/// `stopError` is thrown once the gate opens, for the failing-stop variants.
/// The entry/finish choreography lives in the shared `Gate`.
actor GatedStopMic: MicCaptureProtocol {
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private let stopError: (any Error & Sendable)?
  private let gate = Gate()

  init(stopError: (any Error & Sendable)? = nil) {
    self.stopError = stopError
  }

  func start() async throws { startCalls += 1 }

  func stop() async throws -> Data {
    stopCalls += 1
    await gate.enter()
    if let stopError { throw stopError }
    // Above SyncSTTLimits.minPCMBytes so the transcript isn't dropped by the
    // too-short guard — these suites exercise stop races, not it.
    return Data(count: SyncSTTLimits.minPCMBytes * 2)
  }

  func waitUntilStopEntered() async { await gate.waitUntilEntered() }
  func allowStopToFinish() async { await gate.allowToFinish() }
}
