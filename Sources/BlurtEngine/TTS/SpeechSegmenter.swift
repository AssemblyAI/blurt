/// Cuts text at sentence ends — what `ListeningChunks` uses to split a
/// paragraph too long for one piece, so a piece never starts or ends
/// mid-sentence.
///
/// The rule is the one the AssemblyAI agent runtime measured
/// (`aai-runtime/src/providers/tts/assemblyai-segment.ts`):
///
/// - **Cut at sentence ends only.** Terminal punctuation plus any closing
///   quotes or brackets, followed by whitespace or the end of the text. Never
///   at commas: a clause spoken alone gets a falling final intonation. Line
///   breaks count as sentence ends too, because a heading or list item in a
///   selection often has no punctuation.
/// - **A segment needs at least two words.** One-word "sentences" are usually
///   abbreviations (`Dr.`, `e.g.`), so they join the sentence that follows.
///
/// `maxCharacters` only splits a runaway sentence, such as a paragraph with no
/// punctuation.
enum SpeechSegmenter {
  /// A sentence end: terminal punctuation plus closers, looking ahead for
  /// whitespace or the end so "3.5" and "v1.2" don't match. Curly closers are
  /// included because a typographic `.”` is the common case, not an edge case.
  /// Alternatively, any line break.
  nonisolated(unsafe) private static let boundary = #/[.!?…]["'’”)\]]*(?=\s|$)|\n/#

  static let minWords = 2

  static func segments(of text: String, maxCharacters: Int = 400) -> [String] {
    var sentences: [String] = []
    var start = text.startIndex
    for match in text.matches(of: boundary) {
      appendTrimmed(text[start..<match.range.upperBound], to: &sentences)
      start = match.range.upperBound
    }
    appendTrimmed(text[start...], to: &sentences)
    return mergingShort(sentences).flatMap { split($0, maxCharacters: maxCharacters) }
  }

  private static func appendTrimmed(_ piece: Substring, to sentences: inout [String]) {
    if let trimmed = String(piece).trimmedNonEmpty() { sentences.append(trimmed) }
  }

  /// Joins any sentence shorter than `minWords` onto the sentence after it. A
  /// short sentence at the very end joins the one before it instead.
  static func mergingShort(_ sentences: [String]) -> [String] {
    var merged: [String] = []
    var pending = ""
    for sentence in sentences {
      pending = pending.isEmpty ? sentence : pending + " " + sentence
      if wordCount(pending) >= minWords {
        merged.append(pending)
        pending = ""
      }
    }
    if !pending.isEmpty {
      if let last = merged.popLast() {
        merged.append(last + " " + pending)
      } else {
        merged.append(pending)
      }
    }
    return merged
  }

  /// Splits `segment` at the last whitespace at or before `maxCharacters`. A run
  /// with no whitespace in that span is cut hard at the limit.
  static func split(_ segment: String, maxCharacters: Int) -> [String] {
    var pieces: [String] = []
    var rest = Substring(segment)
    while rest.count > maxCharacters {
      let limit = rest.index(rest.startIndex, offsetBy: maxCharacters)
      let cut = rest[..<limit].lastIndex(where: \.isWhitespace) ?? limit
      if let head = String(rest[..<cut]).trimmedNonEmpty() { pieces.append(head) }
      rest = rest[cut...].drop(while: \.isWhitespace)
    }
    if let tail = String(rest).trimmedNonEmpty() { pieces.append(tail) }
    return pieces
  }

  private static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }
}
