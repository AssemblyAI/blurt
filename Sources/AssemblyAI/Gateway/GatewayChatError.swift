public import Foundation

// periphery:ignore - SDK API: a caller catches it to tell a refused request from an empty reply.
/// The gateway client's errors.
public enum GatewayChatError: Error, Equatable, LocalizedError {
  /// A non-2xx answer from the gateway (0 when the response wasn't HTTP).
  case status(Int)
  /// A 2xx with no text in it.
  case empty

  public var errorDescription: String? {
    switch self {
    case .status(let code):
      "The LLM Gateway answered HTTP \(code)."

    case .empty:
      "The LLM Gateway returned no text."
    }
  }
}
