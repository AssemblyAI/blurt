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
  ///
  /// Carries the silent device's name, because the device is usually the whole
  /// story: an aggregate whose real interface is unplugged, or a loopback like
  /// BlackHole set as the default input, records nothing while every other mic
  /// works. "The microphone didn't start" sent users hunting for a Blurt bug;
  /// naming the device points them at their audio settings. Nil when the name
  /// can't be read (the device vanished mid-press).
  case inputNeverDelivered(deviceName: String?)

  var errorDescription: String? {
    switch self {
    case .noInputDevice: "No microphone is available."
    case .inputNeverDelivered(let deviceName?): "\(deviceName) isn't sending any audio."
    case .inputNeverDelivered(nil): "The microphone isn't sending any audio."
    }
  }
}
