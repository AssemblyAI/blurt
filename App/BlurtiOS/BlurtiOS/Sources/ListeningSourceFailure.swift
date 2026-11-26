import BlurtEngine
import Foundation

/// Why a microphone couldn't open or start. Each case is its own sentence,
/// for the home screen; `CaptureFailure` turns each into the keyboard's
/// `FailureReason`. `CaptureFailureWording` tells the engine the sentence is
/// written for the user, so a failed phase says it without the
/// "Audio capture failed: …" prefix.
nonisolated enum ListeningSourceFailure: LocalizedError, CaptureFailureWording, Equatable {
  /// A press arrived with no listening window open — the keyboard's job is to
  /// open the app first, so this is a plumbing fault, not a user error.
  case windowClosed
  /// The phone has no audio input at all.
  case noInputDevice
  /// iOS has the input: a call, Siri, another app recording. `reason` is the
  /// system's name for why.
  case interrupted(reason: String)
  /// The capture session died while running; `code` is the system's.
  case runtimeError(code: Int)
  /// The session refused its input or output; `code` is the system's, 0 when
  /// it gave none.
  case configureFailed(code: Int)
  /// The microphone came up and delivered only digital silence.
  case inputSilent
  /// An interruption ended and the session didn't come back.
  case couldNotResume
  /// A parked start from the background that iOS refused: the session was
  /// left not running with no interruption to blame, and `code` is the error
  /// it posted, 0 when it posted none. The remedy is the foreground.
  case backgroundStartRefused(code: Int)

  var errorDescription: String? {
    switch self {
    case .windowClosed:
      "The session is off."

    case .noInputDevice:
      "No microphone is available."

    case .interrupted:
      "A call or another app has the microphone."

    case .runtimeError:
      "The microphone stopped unexpectedly."

    case .configureFailed:
      "The microphone couldn't be set up."

    case .inputSilent:
      "The microphone isn't sending any audio."

    case .couldNotResume:
      "The microphone didn't come back after the interruption."

    case .backgroundStartRefused:
      "Open Blurt to start the microphone."
    }
  }
}
