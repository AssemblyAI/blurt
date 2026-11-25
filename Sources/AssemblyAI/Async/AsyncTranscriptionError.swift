import Foundation

enum AsyncTranscriptionError: Error, Equatable, LocalizedError {
  /// A non-2xx response, with the API's `error` sentence when it sent one.
  case http(status: Int, message: String?)
  /// The transcript finished with `status: "error"`.
  case failed(String?)

  var errorDescription: String? {
    switch self {
    case let .http(status, message?):
      "AssemblyAI error \(status): \(message)"

    case .http(let status, nil):
      "AssemblyAI error \(status)"

    case .failed(let message?):
      "Transcription failed: \(message)"

    case .failed(nil):
      "Transcription failed."
    }
  }
}
