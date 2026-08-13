import CoreAudio
import Foundation

/// The pure decision half of `MicCapture.start()`'s liveness gate: how long to
/// wait for the input device to actually deliver frames, and the polling loop
/// that detects when it has. Kept out of the hardware-bound capture actor (the
/// same split as `MicCapture+Meter`) so the timeout policy and the wait's
/// edge cases are unit-tested against an injected clock.
enum MicLiveness {
  /// How often the recorder's clock is re-checked while waiting.
  static let pollInterval: Duration = .milliseconds(50)

  /// Wait cap for Bluetooth inputs: bringing an AirPods mic up means an
  /// A2DP→HFP profile switch that takes ~1–2 s, and macOS drops the link back
  /// to A2DP a few seconds after every stop — so every dictation after an idle
  /// gap pays it again, not just the first.
  static let bluetoothTimeout: Duration = .milliseconds(2500)

  /// Wait cap for every other transport (and an unreadable one): wired and
  /// built-in inputs deliver frames near-instantly, so a route that hasn't
  /// within this budget is broken and the gate fails open without ever making
  /// a healthy mic feel laggy.
  static let defaultTimeout: Duration = .milliseconds(300)

  /// The wait cap for an input device of the given CoreAudio transport type
  /// (`kAudioDevicePropertyTransportType`); nil means the type couldn't be
  /// read, which gets the conservative default cap.
  static func timeout(forTransportType transportType: UInt32?) -> Duration {
    switch transportType {
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      bluetoothTimeout
    default:
      defaultTimeout
    }
  }

  /// Polls `currentTime` every `pollInterval` until it advances past zero. The
  /// recorder's clock only moves once the input device delivers frames, which
  /// is what distinguishes "route still switching" (clock stuck at 0) from
  /// "user is silent" (clock advancing over quiet audio) — a meter level can't.
  ///
  /// Returns the elapsed wait once frames flow, or nil when `timeout` (or a
  /// task cancellation) won the race. The caller FAILS OPEN on nil — proceeding
  /// exactly as if live — because a silent or broken mic must degrade to the
  /// old behavior, never brick the press.
  static func waitUntilLive(
    timeout: Duration,
    clock: some Clock<Duration>,
    currentTime: @escaping @Sendable () -> TimeInterval
  ) async -> Duration? {
    let start = clock.now
    let deadline = start.advanced(by: timeout)
    while currentTime() <= 0 {
      guard clock.now < deadline, !Task.isCancelled else { return nil }
      try? await clock.sleep(for: pollInterval)
    }
    return start.duration(to: clock.now)
  }
}
