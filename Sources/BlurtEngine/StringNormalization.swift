import Foundation

extension Optional where Wrapped == String {
  /// The wrapped string trimmed of surrounding whitespace and newlines, or `nil`
  /// when it's absent or blank. The single definition of "usable text" shared by
  /// focus capture, the transcription context turns, and the key-term / key
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

  /// The longest prefix of whole `Character`s whose UTF-8 encoding fits
  /// `maxUTF8Bytes` — the one truncation rule behind the custom style budget,
  /// shared by the Settings field and the engine-side trim
  /// (`CleanupInstruction.sendable(appending:)`). Drops graphemes from the end
  /// rather than slicing bytes, so a multi-scalar emoji is removed whole, never
  /// split into an invalid fragment.
  public func prefix(maxUTF8Bytes: Int) -> String {
    var result = self
    while result.utf8.count > maxUTF8Bytes, !result.isEmpty {
      result.removeLast()
    }
    return result
  }
}
