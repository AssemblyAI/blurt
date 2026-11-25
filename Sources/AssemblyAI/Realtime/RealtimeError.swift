import Foundation

enum RealtimeError: Error, Equatable, LocalizedError {
  /// The socket failed or the service closed it, with its reason.
  case connection(String)

  var errorDescription: String? {
    switch self {
    case .connection(let reason):
      "The live transcription stopped: \(reason)"
    }
  }
}
