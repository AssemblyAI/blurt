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
/// the mirror image for the release path. `HotkeyRaceTests` drives its
/// press/release races through this one too.
actor GatedStartMic: MicCaptureProtocol {
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private(set) var cancelCaptureCalls = 0
  private let gate = Gate()
  /// When set, `start()` throws `CancellationError` if the task was cancelled
  /// while it was gated — what the real `MicCapture` does when a cancel lands
  /// during its liveness wait. Off by default so the common gated-press tests
  /// see a bring-up that simply completes.
  private var throwsIfCancelled = false
  /// When set, `start()` throws this once released, cancelled or not — what the
  /// real `MicCapture` does when the device open fails (`record()` answering
  /// false) while a cancel is landing.
  private var failure: (any Error)?

  /// No meter: the bring-up races under test never read one.
  nonisolated var levels: AsyncStream<Float> { .finished }

  func setThrowsIfCancelled(_ value: Bool) { throwsIfCancelled = value }
  func setFailure(_ error: (any Error)?) { failure = error }

  func start() async throws -> AsyncStream<Data> {
    startCalls += 1
    await gate.enter()
    if throwsIfCancelled, Task.isCancelled { throw CancellationError() }
    if let failure { throw failure }
    return .oneShot(StubPCM.aboveMinimum)
  }

  func waitUntilStartEntered() async { await gate.waitUntilEntered() }
  func allowStartToFinish() { gate.allowToFinish() }

  func stop() -> Int {
    stopCalls += 1
    return StubPCM.aboveMinimum.count
  }

  /// Counts the call and delegates, so `stopCalls` keeps meaning "the mic was
  /// stopped" however the teardown was reached — the same shape as
  /// `StubMicCapture`.
  func cancelCapture() {
    cancelCaptureCalls += 1
    _ = stop()
  }

  func warmUp() {
    // Nothing to pre-pay: the stub opens no device.
  }
}
