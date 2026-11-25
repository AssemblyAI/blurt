import Foundation

enum SelectionRewriteError: Error, Equatable, LocalizedError {
  /// The selection is past `SelectionRewriter.maxCharacters`.
  case tooLong

  var errorDescription: String? {
    switch self {
    case .tooLong:
      "The selection is too long to rewrite."
    }
  }
}
