import Foundation

extension Optional where Wrapped == String {
  /// The wrapped string trimmed of surrounding whitespace and newlines, or `nil`
  /// when it's absent or blank. The single definition of "usable text" shared by
  /// focus capture, the transcription context turns, and the key-term / key
  /// stores — so the trim-and-treat-blank-as-empty rule lives in one place.
  public func trimmedNonEmpty() -> String? {
    guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
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

extension StringProtocol {
  // periphery:ignore - public for the iOS app's dictation stats (App/BlurtiOS), which the Mac scan doesn't index.
  /// How many words the text holds: whitespace-separated runs with a letter or
  /// digit in them, so a lone "—" or "…" between words isn't one. The one
  /// definition of a word, for read-aloud's chunking, the Library's counts and
  /// the iPhone's dictation stats. A single pass over the scalars: no array of
  /// words, and no grapheme segmentation, on a transcript that can run to tens
  /// of thousands of words. Text written without spaces between words counts
  /// as one word per run.
  public var wordCount: Int {
    var count = 0
    var counted = false
    for scalar in unicodeScalars {
      if scalar.properties.isWhitespace {
        counted = false
      } else if !counted, scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
        counted = true
        count += 1
      }
    }
    return count
  }
}
