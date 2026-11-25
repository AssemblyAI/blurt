import Foundation

enum ReadAloudLLMError: Error, Equatable, LocalizedError {
  /// A reply with no usable text in it (`TranscriptLLM.title`).
  case empty
  /// The rewrite stopped at `max_tokens`, part-way through the selection.
  case truncated
  /// The rewrite is too much longer than the input to be a rewrite of it.
  case implausible

  var errorDescription: String? {
    switch self {
    case .empty:
      "The LLM Gateway returned no text."

    case .truncated:
      "The LLM Gateway's rewrite was cut short."

    case .implausible:
      "The LLM Gateway's rewrite didn't match the selection."
    }
  }
}
