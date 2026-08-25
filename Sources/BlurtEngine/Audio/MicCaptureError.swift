import Foundation

/// The capture-specific faults `MicCapture.start()` wraps in
/// `BlurtError.audioCaptureFailed`, whose description interpolates them into
/// the overlay's error pill — so each message must read like a sentence, not
/// the "(… error 0.)" gibberish a bare enum produces (pinned in
/// `MicCaptureFormatTests`).
///
/// Its own file rather than a tail of `MicCapture.swift` for the same two
/// reasons the meter math lives in `MicCapture+Meter.swift`: the capture actor
/// is at the lint file-length budget, and this enum is pure — unlike the
/// hardware-bound actor it serves, the coverage gate counts it, and the message
/// tests keep it green.
enum MicCaptureError: LocalizedError {
  /// The active audio route reported no usable input device.
  case noInputDevice
  /// The recorder started but the input never confirmed real signal within
  /// `MicLiveness`'s cap — the device delivered nothing (or only digital
  /// silence) for the whole wait, so the press fails closed rather than
  /// recording an utterance the mic isn't receiving.
  case inputNeverDelivered

  var errorDescription: String? {
    switch self {
    case .noInputDevice: "No microphone is available."
    case .inputNeverDelivered: "The microphone didn't start."
    }
  }
}

/// A CoreAudio call the pinned-device recorder couldn't get past, carrying which
/// call and the `OSStatus` it answered — the two facts a field report needs to
/// be actionable. Reaches the overlay the same way `MicCaptureError` does
/// (interpolated by `BlurtError.audioCaptureFailed`), so the message carries the
/// same read-like-a-sentence requirement, pinned in `MicCaptureFormatTests`.
/// Declared here beside `MicCaptureError` — not in the recorder's own file —
/// because it is pure, so the coverage gate counts it and the message test keeps
/// it green.
struct AudioQueueError: LocalizedError {
  /// The CoreAudio call that refused, e.g. `"AudioQueueNewInput"`.
  let operation: String
  let status: OSStatus

  var errorDescription: String? {
    "The selected microphone couldn't be opened (\(operation): error \(status))."
  }
}
