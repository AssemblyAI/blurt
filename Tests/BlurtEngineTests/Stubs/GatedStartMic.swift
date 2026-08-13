import Foundation

@testable import BlurtEngine

/// Mic stub whose `start()` blocks until the test releases it, so a command can
/// be landed while the session sits in `.connecting`.
///
/// That window is not hypothetical: `MicCapture.start()` holds until the input
/// route delivers frames, which on a Bluetooth route is up to
/// `MicLiveness.bluetoothTimeout`. Before the gate existed, `start()` returned in
/// microseconds and nothing could arrive during a press.
///
/// The entry/finish choreography lives in the shared `Gate`; `GatedStopMic` is
/// the mirror image for the release path. `HotkeyRaceTests` keeps its own private
/// gated-start stub predating this one — left alone rather than folded in, since
/// swapping a stub under a passing race suite risks more than the duplication
/// costs.
actor GatedStartMic: MicCaptureProtocol {
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private(set) var cancelCaptureCalls = 0
  private let gate = Gate()

  func start() async throws {
    startCalls += 1
    await gate.enter()
  }

  func waitUntilStartEntered() async { await gate.waitUntilEntered() }
  func allowStartToFinish() { gate.allowToFinish() }

  func stop() async throws -> Data {
    stopCalls += 1
    return StubPCM.aboveMinimum
  }

  /// Counts the call and delegates, so `stopCalls` keeps meaning "the mic was
  /// stopped" however the teardown was reached — the same shape as
  /// `StubMicCapture`.
  func cancelCapture() async throws {
    cancelCaptureCalls += 1
    _ = try await stop()
  }
}
