public import Foundation

/// The dictation client's errors.
public enum AssemblyAIError: Error, LocalizedError {
  /// A non-2xx answer, with the service's own sentence when it sent one.
  case http(status: Int, message: String?)
  /// A 2xx whose body isn't the documented response.
  case malformedResponse
  /// The recording ended below the client's `minimumAudioBytes`, so the body
  /// was never closed rather than paying for a request that transcribes
  /// nothing.
  case audioTooShort
  /// The streaming route refused the recording past its cap, and the copy that
  /// backs the buffered fallback outgrew `DictationClient.maxBufferedAudioBytes`
  /// before the recording ended — so there is no whole recording to send, and
  /// sending what was kept would return a transcript silently missing its end.
  /// Unreachable at 16 kHz mono (a 20-minute recording is ~38 MB of PCM against
  /// a 256 MB guard); it exists so a geometry change fails here rather than in
  /// the service's own `400`.
  case recordingTooLarge

  public var errorDescription: String? {
    switch self {
    case let .http(status, message):
      if let message {
        return "AssemblyAI error \(status): \(message)"
      }
      return "AssemblyAI error \(status)"

    case .malformedResponse:
      return "Unexpected response from AssemblyAI."

    case .audioTooShort:
      return "That recording was too short to transcribe."

    case .recordingTooLarge:
      return "That recording was too large to transcribe."
    }
  }
}
