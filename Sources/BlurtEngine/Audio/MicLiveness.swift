import Foundation

/// The pure decision half of `MicCapture.start()`'s liveness gate: how long to
/// wait for the input device to actually deliver frames, and the polling loop
/// that detects when it has. Kept out of the hardware-bound capture actor (the
/// same split as `MicCapture+Meter`) so the timeout policy and the wait's edge
/// cases are unit-tested against an injected clock.
enum MicLiveness {
  /// The first re-check delay, doubling up to `maxPollInterval`.
  ///
  /// Geometric rather than a fixed quantum because the two cases this loop
  /// serves want opposite things. `AVAudioRecorder.currentTime` is 0 the instant
  /// `record()` returns, so *every* press sleeps at least once before
  /// `.recording`, the start chime and the meter — on a wired mic that quantum
  /// is the entire wait, and it should be as small as possible. A real Bluetooth
  /// bring-up, meanwhile, runs to seconds, where a small fixed quantum is
  /// hundreds of timer wakeups each doing a clock read for an answer that hasn't
  /// changed. Starting at 1 ms and doubling gives the common case a ~1 ms
  /// acknowledgement and the slow case ~30 wakeups instead of 250, at the cost
  /// of at most one `maxPollInterval` of detection granularity out of a 1–2 s
  /// wait.
  static let initialPollInterval: Duration = .milliseconds(1)

  /// Ceiling for the backoff — the coarsest the loop ever gets.
  static let maxPollInterval: Duration = .milliseconds(25)

  /// Wait cap for Bluetooth inputs: bringing an AirPods mic up means a profile
  /// switch into the mic-capable mode that takes ~1–2 s, and the link drops back
  /// to the output-only profile after an idle gap — so a dictation after a pause
  /// pays it again, not just the first one.
  ///
  /// `MicCapture`'s re-warm shortens how *often* this is paid (it keeps the
  /// input open between dictations); this cap governs what happens when it is
  /// paid anyway.
  static let bluetoothTimeout: Duration = .milliseconds(2500)

  /// Wait cap for every other transport (and an unreadable one): wired and
  /// built-in inputs deliver frames near-instantly, so a route that hasn't
  /// within this budget is broken and the gate fails open without ever making a
  /// healthy mic feel laggy.
  static let defaultTimeout: Duration = .milliseconds(300)

  /// The wait cap for an input device of the given CoreAudio transport type
  /// (`kAudioDevicePropertyTransportType`); nil means the type couldn't be read,
  /// which gets the conservative default cap.
  static func timeout(forTransportType transportType: UInt32?) -> Duration {
    AudioTransport.isBluetooth(transportType) ? bluetoothTimeout : defaultTimeout
  }

  /// Polls `currentTime` on a backoff (see `initialPollInterval`) until it
  /// advances past zero. The recorder's clock only moves once the input device
  /// delivers frames, which is what distinguishes "route still switching" (clock
  /// stuck at 0) from "user is silent" (clock advancing over quiet audio) — a
  /// meter level can't.
  ///
  /// Returns the elapsed wait once frames flow, or nil when `timeout` (or a task
  /// cancellation) won the race. The caller FAILS OPEN on nil — proceeding
  /// exactly as if live — because a silent or broken mic must degrade to the old
  /// behavior, never brick the press.
  static func waitUntilLive(
    timeout: Duration,
    clock: some Clock<Duration>,
    currentTime: @escaping @Sendable () -> TimeInterval
  ) async -> Duration? {
    let start = clock.now
    let deadline = start.advanced(by: timeout)
    var interval = initialPollInterval
    while currentTime() <= 0 {
      guard clock.now < deadline, !Task.isCancelled else { return nil }
      try? await clock.sleep(for: interval)
      interval = min(interval * 2, maxPollInterval)
    }
    return start.duration(to: clock.now)
  }
}
