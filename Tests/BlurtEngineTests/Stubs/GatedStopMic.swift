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

  func start() -> AsyncStream<Data> {
    startCalls += 1
    return .oneShot(StubPCM.aboveMinimum)
  }

  func stop() async throws -> Int {
    stopCalls += 1
    await gate.enter()
    if let stopError { throw stopError }
    // These suites exercise stop races, not the too-short-audio guard.
    return StubPCM.aboveMinimum.count
  }

  /// No meter: the races under test never read one.
  nonisolated var levels: AsyncStream<Float> { .finished }

  /// Stop and discard: the stub's only teardown is `stop()`.
  func cancelCapture() async throws {
    _ = try await stop()
  }

  func warmUp() {
    // Nothing to pre-pay: the stub opens no device.
  }

  func waitUntilStopEntered() async { await gate.waitUntilEntered() }
  func allowStopToFinish() { gate.allowToFinish() }
}
