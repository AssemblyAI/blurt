import Foundation

public enum BlurtError: Error, Sendable {
  case microphonePermissionDenied
  case accessibilityPermissionMissing
  case apiKeyMissing
  case sttFailed(underlying: Error)
  case targetAppLost
  case audioCaptureFailed(underlying: Error)
  /// Nothing editable was focused at paste time, so the transcript was left on
  /// the clipboard instead of synthesizing a ⌘V that macOS would just reject with
  /// a beep. Not a fault — the pipeline maps it to a quiet "copied" notice, not
  /// the red error flash.
  case noEditableTarget
}

extension BlurtError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .microphonePermissionDenied: "Microphone access is required."
    case .accessibilityPermissionMissing: "Accessibility access is required."
    case .apiKeyMissing: "Add your AssemblyAI API key in Settings to start dictating."
    case .sttFailed(let e): "Transcription failed: \(e.localizedDescription)"
    case .targetAppLost: "Target app lost focus or quit."
    case .audioCaptureFailed(let e): "Audio capture failed: \(e.localizedDescription)"
    case .noEditableTarget: "No text field was focused — copied to the clipboard instead."
    }
  }
}
