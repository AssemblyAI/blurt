public import Foundation

// periphery:ignore - SDK API: a caller catches it to tell a stalled stream from a refused request.
/// The TTS client's errors.
public enum SpeechSynthesisError: Error, Equatable, LocalizedError {
  /// The response went quiet for longer than `SpeechClient.timeout`.
  case timedOut
  /// A failed request, e.g. `(unauthorized) Invalid API key`.
  case server(String)

  public var errorDescription: String? {
    switch self {
    case .timedOut:
      "Text-to-speech stopped responding."

    case .server(let message):
      "Text-to-speech failed: \(message)"
    }
  }
}
