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

  /// Wait cap for a transport known to be wired or on-board
  /// (`AudioTransport.isLocal`): those inputs deliver frames near-instantly, so
  /// a route that hasn't within this budget is broken and the gate fails open
  /// without ever making a healthy mic feel laggy.
  static let defaultTimeout: Duration = .milliseconds(300)

  /// Wait cap for a transport that is neither Bluetooth nor recognisably local:
  /// an aggregate or virtual input, a type `AudioTransport` doesn't name, or a
  /// transport property that couldn't be read at all.
  ///
  /// Those cases used to take `defaultTimeout`, which is the one budget that
  /// cannot be right for them — AirPods sitting behind a virtual mic (Krisp,
  /// BlackHole, Loopback, a conferencing app's device) or inside an aggregate
  /// still pay the ~1–2 s HFP switch, and the wrapper reports its own transport,
  /// so the gate returned before the link was up and the first words were lost
  /// anyway. `bluetoothTimeout` would be the other error: a genuinely dead
  /// virtual device would feel like a 2.5 s hang on every press. This splits
  /// them — long enough to cover most of a profile switch, short enough that the
  /// fail-open path still feels like a stutter rather than a stall.
  static let unknownTransportTimeout: Duration = .milliseconds(1000)

  /// The dBFS meter reading at or below which a poll counts as *digital*
  /// silence — zero-filled buffers from a device that hasn't started delivering
  /// — rather than a live input.
  ///
  /// This is not a speech threshold and must never be raised into one. All it
  /// has to separate is "the buffers are literally zeroes" from "the ADC is
  /// handing us something": `averagePower(forChannel:)` reports dBFS in roughly
  /// `[-160, 0]`, a zero-filled buffer bottoms out at or near -160, and a single
  /// least-significant bit of a 16-bit sample is already about -90, so any real
  /// analog noise floor — including a live mic in a dead-quiet room, which still
  /// reads its own self-noise — sits far above this. -115 is in the empty band
  /// between the two.
  ///
  /// A speech-level floor (`MicCapture.meterFloorDB` is -50) would turn this
  /// gate into voice-activity detection and hang every press in a quiet room
  /// until the cap, which is the same bug in the other direction. It also means
  /// no grace period is needed for the quiet user: a live mic clears this
  /// immediately whether or not anyone is talking.
  static let silenceFloorDB: Float = -115

  /// The wait cap for an input device of the given CoreAudio transport type
  /// (`kAudioDevicePropertyTransportType`). Three answers, not two — see
  /// `unknownTransportTimeout` for why nil and the unclassifiable transports
  /// can't share the local cap.
  static func timeout(forTransportType transportType: UInt32?) -> Duration {
    if AudioTransport.isBluetooth(transportType) { return bluetoothTimeout }
    return AudioTransport.isLocal(transportType) ? defaultTimeout : unknownTransportTimeout
  }

  /// The one line `MicCapture` logs when the gate returns, worded here so the
  /// text a field report is read off is unit-tested rather than assembled at an
  /// untested call site — `MicCapture` needs real hardware and is excluded from
  /// the coverage gate.
  ///
  /// It has to answer the three questions a user's `log show` output is fetched
  /// to settle: which cap applied (the **raw** CoreAudio transport value, not a
  /// classification, so a device that landed in `unknownTransportTimeout` can be
  /// identified), how long the gate actually held, and what the meter read when
  /// it returned — a value near -160 on a confirmed start is the all-zero-buffer
  /// premise showing itself. `gap == nil` is the fail-open outcome, which the
  /// caller logs at `.error` and a confirmed one at `.info`.
  static func logSummary(
    gap: Duration?,
    timeout: Duration,
    transportType: UInt32?,
    powerDB: Float
  ) -> String {
    let transport = transportType.map { "\($0)" } ?? "nil"
    let route = "transport=\(transport) powerDB=\(powerDB)"
    guard let gap else {
      let cap = Int(timeout.milliseconds.rounded())
      return "input liveness unconfirmed after \(cap) ms — proceeding, \(route)"
    }
    return "input live after \(Int(gap.milliseconds.rounded())) ms, \(route)"
  }

  /// Polls the recorder on a backoff (see `initialPollInterval`) until it is
  /// genuinely live: the clock has advanced past zero **and** one meter reading
  /// is above `silenceFloorDB`.
  ///
  /// The clock alone is not enough, which is what shipped and what still lost
  /// the first words on AirPods. macOS can hand a stale or not-yet-switched
  /// device's queue **all-zero buffers** (the failure that retired the
  /// `AVAudioEngine` capture path — see `MicCapture`'s header), and frames of
  /// digital silence advance `currentTime` exactly like real audio does. So the
  /// clock term was satisfied on the first ~1 ms poll while the link was still
  /// renegotiating, the gate returned immediately, and the "Connecting…" pill
  /// flashed past instead of holding.
  ///
  /// The power term is a *device is delivering real samples* test, not a
  /// voice-activity one — see `silenceFloorDB`. Short-circuited, so a recorder
  /// whose clock hasn't moved is never metered.
  ///
  /// Returns the elapsed wait once the input is live, or nil when `timeout` (or
  /// a task cancellation) won the race. The caller FAILS OPEN on nil —
  /// proceeding exactly as if live — because a silent or broken mic must degrade
  /// to the old behavior, never brick the press. That remains the only escape
  /// hatch: a non-finite or `-infinity` reading counts as not-live and lands
  /// here, which is the conservative direction.
  static func waitUntilLive(
    timeout: Duration,
    clock: some Clock<Duration>,
    currentTime: @escaping @Sendable () -> TimeInterval,
    inputPowerDB: @escaping @Sendable () -> Float
  ) async -> Duration? {
    let start = clock.now
    let deadline = start.advanced(by: timeout)
    var interval = initialPollInterval
    // Negated `>` rather than `<=` on purpose: a NaN reading fails both
    // comparisons, and this spelling makes that "not live" instead of "live".
    while currentTime() <= 0 || !(inputPowerDB() > silenceFloorDB) {
      guard clock.now < deadline, !Task.isCancelled else { return nil }
      try? await clock.sleep(for: interval)
      interval = min(interval * 2, maxPollInterval)
    }
    return start.duration(to: clock.now)
  }
}
