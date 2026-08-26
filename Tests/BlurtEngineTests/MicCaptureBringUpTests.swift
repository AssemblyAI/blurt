import Foundation
import Testing

@testable import BlurtEngine

/// Does a teardown land *during* the device open, or queue behind it?
///
/// `record()` opens the device, and how long that takes is entirely the
/// hardware's business: ~100 ms on AirPods (the link returns early and delivers
/// frames later), ~600 ms on a USB interface, ~180 ms on the built-in mic. While
/// it runs, nothing else can use the capture actor unless the call is off-actor —
/// which is what this suite pins.
///
/// Live-gated, and self-calibrating: it measures the open first and skips its own
/// assertion when the device it has is too fast for the question to be visible.
/// Set `BLURT_LIVE_AUDIO_INPUT_UID` to a device UID (see the Settings picker, or
/// `AudioInputDevices.all()`) to point it at a slower input than the system
/// default — that is how the USB case gets covered on a machine whose default is
/// Bluetooth.
@Suite(
  "MicCapture bring-up (live)",
  .enabled(
    if: ProcessInfo.processInfo.environment["BLURT_LIVE_AUDIO_TESTS"] == "1",
    "set BLURT_LIVE_AUDIO_TESTS=1 to run (needs a real microphone)"),
  .tags(.liveAudio),
  .serialized,
  .timeLimit(.minutes(1)))
struct MicCaptureBringUpTests {
  /// The input this suite exercises: the env-named device, else the system
  /// default.
  private static var pinnedUID: String? {
    ProcessInfo.processInfo.environment["BLURT_LIVE_AUDIO_INPUT_UID"]
  }

  private static var selection: MicDeviceSelection {
    pinnedUID.map { MicDeviceSelection.pinned(uid: $0) } ?? .systemDefault
  }

  @Test("a teardown during the device open isn't blocked by it")
  func teardownDuringOpenIsNotBlocked() async throws {
    let clock = ContinuousClock()

    // Calibrate against the real device, since the assertion is a comparison
    // against its open cost rather than a fixed budget.
    let probe = try CaptureSessionRecorder(pinnedUID: Self.pinnedUID)
    let openStart = clock.now
    _ = await probe.record()
    let openCost = clock.now - openStart
    probe.stopAndDiscard()

    guard openCost > .milliseconds(150) else {
      // Not a failure: on a fast input there is no window to land inside, so
      // there is nothing here to get wrong. Named rather than silently passing.
      print(
        "MicCaptureBringUpTests: input opens in \(openCost) — too fast to observe the window; "
          + "set BLURT_LIVE_AUDIO_INPUT_UID to a slower device to cover this")
      return
    }

    // A press, then an unqueued teardown a beat later — the shape a host that
    // doesn't serialize its own commands produces. `DictationSession` does
    // serialize (its release/cancel run only after the press turn completes), but
    // this is a public actor and the contract has to hold without that.
    let mic = MicCapture(deviceSelection: { Self.selection })
    async let started: Void = mic.start()
    try await Task.sleep(for: .milliseconds(30))
    let cancelStart = clock.now
    try await mic.cancelCapture()
    let cancelCost = clock.now - cancelStart
    _ = try? await started

    #expect(
      cancelCost < openCost / 2,
      """
      cancelCapture took \(cancelCost) while an open costing \(openCost) was in flight — \
      the actor was blocked for the duration of the open
      """)
  }
}
