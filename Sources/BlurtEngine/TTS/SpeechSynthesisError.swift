import Foundation

enum SpeechSynthesisError: Error, Equatable, LocalizedError {
  /// The response went quiet for longer than `AssemblyAISpeechSynthesizer.timeout`.
  case timedOut
  /// A failed request, e.g. `(unauthorized) Invalid API key`.
  case server(String)

  var errorDescription: String? {
    switch self {
    case .timedOut:
      "Text-to-speech stopped responding."

    case .server(let message):
      "Text-to-speech failed: \(message)"
    }
  }
}
