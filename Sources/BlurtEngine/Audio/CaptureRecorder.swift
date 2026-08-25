import Foundation

/// The one-session recording surface `MicCapture` drives. A seam rather than a
/// direct dependency so the capture actor's machinery — the liveness gate, the
/// meter, the warm recorder, the tail linger — is written against this small
/// contract instead of a concrete recorder; `CaptureSessionRecorder` is the one
/// production conformer (owner-directed move to `AVCaptureSession`,
/// 2026-08-25), built fresh per session, which is the invariant the capture
/// design rests on.
///
/// `Sendable` because `MicCapture.start()`'s liveness probes read the recorder
/// off-actor; conformers are `@unchecked Sendable` on the same confinement
/// argument the retired recorders relied on there — the polls run sequentially
/// in one task while `start()` is suspended and nothing else references the
/// recorder in that window (the session backend additionally locks the state
/// its delegate queue shares).
protocol CaptureRecorder: AnyObject, Sendable {
  /// Begin capturing. False when no usable input device is available.
  func record() -> Bool
  /// Seconds the recorder's clock has advanced since `record()` — 0 until
  /// audio is actually being delivered. Consulted only as the liveness gate's
  /// has-the-clock-moved probe; frames of digital silence advance it exactly
  /// like real audio (see `MicLiveness.waitUntilLive`).
  var currentTime: TimeInterval { get }
  /// Refresh and read the input's average power in dBFS. Feeds both the
  /// liveness gate's silence-floor probe and the overlay meter.
  func meteredPowerDB() -> Float
  /// End capture and return everything recorded as raw S16LE PCM at the
  /// dictation API's rate, releasing the device.
  func stopAndReadPCM() throws -> Data
  /// End capture and throw the audio away, releasing the device — the teardown
  /// behind a failed `record()`, an aborted bring-up, a discarded warm
  /// recorder, and a cancel.
  func stopAndDiscard()
  /// A short name for the capture-start log line.
  var logName: String { get }
}

extension MicCapture {
  /// The recorder for a resolved input. One conformer either way — the session
  /// pins itself to the device when a UID is passed and follows the system
  /// default when nil — so this stays the single place a backend is chosen,
  /// exactly as it was when there were two.
  static func makeBackend(pinnedUID: String?) throws -> any CaptureRecorder {
    try CaptureSessionRecorder(pinnedUID: pinnedUID)
  }
}
