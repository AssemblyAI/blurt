import Foundation

extension Optional where Wrapped == String {
  /// The wrapped string trimmed of surrounding whitespace and newlines, or `nil`
  /// when it's absent or blank. The single definition of "usable text" shared by
  /// focus capture, the transcription context/prompt, and the key-term / key
  /// stores — so the trim-and-treat-blank-as-empty rule lives in one place.
  public func trimmedNonEmpty() -> String? {
    guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

extension String {
  /// Non-optional companion to `Optional.trimmedNonEmpty()`, so a plain `String`
  /// (API key, transcript) shares the same "usable text" rule without wrapping.
  public func trimmedNonEmpty() -> String? {
    Optional(self).trimmedNonEmpty()
  }
}
