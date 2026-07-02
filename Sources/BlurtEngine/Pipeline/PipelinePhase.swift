import Foundation

public enum PipelinePhase: Equatable, Sendable {
  case idle
  case recording
  case transcribing
  case injecting
  case failed(BlurtError)
  case cancelled
  /// Transcription succeeded and the text was pasted into the focused field. A
  /// terminal, non-error outcome — the overlay shows a quiet "pasted" notice as
  /// the mirror of `.noTarget`'s "copied" notice before settling back to idle.
  case pasted
  /// Transcription succeeded but the paste had nowhere to land — no editable
  /// field was focused, or the target app quit/refused activation — so the text
  /// was left on the clipboard. A terminal, non-error outcome — the overlay
  /// shows a quiet "copied" notice rather than the red failure flash.
  case noTarget

  public var isTerminal: Bool {
    switch self {
    case .idle, .failed, .cancelled, .pasted, .noTarget: true
    default: false
    }
  }
}

extension BlurtError: Equatable {
  public static func == (lhs: BlurtError, rhs: BlurtError) -> Bool {
    switch (lhs, rhs) {
    case (.microphonePermissionDenied, .microphonePermissionDenied),
      (.accessibilityPermissionMissing, .accessibilityPermissionMissing),
      (.apiKeyMissing, .apiKeyMissing),
      (.targetAppLost, .targetAppLost),
      (.noEditableTarget, .noEditableTarget):
      return true
    case (.sttFailed(let a), .sttFailed(let b)),
      (.audioCaptureFailed(let a), .audioCaptureFailed(let b)):
      // Compare wrapped errors by their bridged NSError identity (domain + code)
      // rather than `localizedDescription`. The description is human-facing copy:
      // comparing it would make equality silently depend on message wording, so a
      // localization or phrasing tweak could break a test. Domain + code is the
      // stable identity of the underlying error.
      let na = a as NSError
      let nb = b as NSError
      return na.domain == nb.domain && na.code == nb.code
    default:
      return false
    }
  }
}
