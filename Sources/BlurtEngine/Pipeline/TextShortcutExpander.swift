import Foundation

/// Replaces each spoken shortcut trigger in a finished transcript with its
/// expansion — "my handle is personal GitHub" → "my handle is
/// https://github.com/…". Pure and local: it runs on the text the dictation API
/// returned, between the response and the paste.
///
/// Matching is forgiving about what the transcription and the cleanup rewrite
/// do to a phrase, and strict about where it starts and ends:
///
/// - **Case-insensitive**, since the rewrite capitalizes freely ("Personal
///   email").
/// - **Separators between words are loose**: any run of characters that
///   aren't letters or digits, or none at all — so "link tree" also matches
///   "Linktree", "cal.com" matches "Cal com", and "mom's address" matches
///   "Mom’s address". Only letters and digits in the trigger are significant,
///   which is exactly what `TextShortcutStore.matchKey` dedupes on.
/// - **Never across a sentence or clause break**: sentence punctuation
///   (`.,!?;:`) followed by whitespace ends the run, so "work email" leaves "my
///   work. Email me" alone while "cal.com" still matches.
/// - **Whole words**: a trigger never matches inside a longer word, so
///   "personal email" leaves "impersonal emails" alone.
///
/// One pass over the text, longest trigger first, so an expansion is never
/// itself re-expanded and "personal email work" wins over "personal email".
enum TextShortcutExpander {
  /// Sentence punctuation the cleanup rewrite adds to a lone phrase. A
  /// dictation that is nothing but a trigger ("Personal email.") pastes the
  /// bare expansion — a trailing period glued to an address or URL is never
  /// what someone dictating a snippet on its own wanted.
  private static let trailingPunctuation = CharacterSet(charactersIn: ".!?,;:")

  static func expand(_ text: String, using shortcuts: [TextShortcut]) -> String {
    let compiled = shortcuts.compactMap { shortcut in
      pattern(for: shortcut.trigger).map { (shortcut, $0) }
    }
    guard !compiled.isEmpty else { return text }

    // A trigger standing alone — surrounding whitespace and closing punctuation
    // aside — becomes exactly its expansion, keeping the original's leading and
    // trailing whitespace so the paste separator logic sees the same shape.
    let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: trailingPunctuation)
    for (shortcut, pattern) in compiled where matchesWhole(core, pattern: pattern) {
      return text.replacingOccurrences(
        of: text.trimmingCharacters(in: .whitespacesAndNewlines), with: shortcut.expansion)
    }

    // Longest first, so a trigger that extends another claims the text before
    // its prefix can.
    let ordered = compiled.sorted { $0.1.count > $1.1.count }
    let alternation = ordered.map { "(\($0.1))" }.joined(separator: "|")
    guard
      let regex = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{M}\\p{N}])(?:\(alternation))(?![\\p{L}\\p{M}\\p{N}])",
        options: [.caseInsensitive])
    else { return text }

    let source = text as NSString
    var result = ""
    var cursor = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
      // Group i+1 is `ordered[i]`; exactly one participates in a match.
      guard
        let index = (0..<ordered.count).first(where: {
          match.range(at: $0 + 1).location != NSNotFound
        })
      else { continue }
      result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      result += ordered[index].0.expansion
      cursor = match.range.location + match.range.length
    }
    result += source.substring(from: cursor)
    return result
  }

  /// What may sit between two of a trigger's words: any run of non-word
  /// characters — the complement of what `words(in:)` keeps (`alphanumerics` is
  /// letters, marks and digits) — except sentence punctuation directly before
  /// whitespace, which is a break in the speech rather than part of a name.
  private static let separatorRun =
    "(?:[^\\p{L}\\p{M}\\p{N}.,!?;:]|[.,!?;:](?!\\s))*"

  /// The regex body for one trigger: its letter/digit runs, escaped, joined by
  /// an optional run of separators. `nil` for a trigger with no letters or
  /// digits, which could only ever match punctuation.
  static func pattern(for trigger: String) -> String? {
    let words = words(in: trigger)
    guard !words.isEmpty else { return nil }
    return words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: separatorRun)
  }

  /// The trigger's letter/digit runs — the only part of it the matcher reads.
  static func words(in trigger: String) -> [String] {
    trigger.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
  }

  /// The fewest characters of an expansion's tail that `redactingExpansions`
  /// treats as a clipped copy at the very start of `text`. Below this an overlap
  /// is as likely to be coincidence — a shared "com" or "." — as a clip.
  static let minimumClippedOverlap = 4

  /// `text` with every expansion in it put back to its trigger — the inverse of
  /// `expand`, for the text before the caret that goes out as `stt_prompt`.
  /// After a shortcut is pasted, the field *holds* the saved replacement, and
  /// the next press would read it back and send it; this keeps it local.
  ///
  /// Literal and case-sensitive, since the field holds exactly what was pasted.
  /// Longest expansion first, so one that contains another is caught whole. The
  /// capture reads only the last few hundred characters, so a long expansion can
  /// arrive with its head cut off: a tail of one (at least
  /// `minimumClippedOverlap` long) at the very start of `text` counts too.
  /// Replacing with the trigger rather than nothing keeps the prompt reading as
  /// the continuous passage it is, and leaves the text's last character — which
  /// the paste separator reads — whitespace exactly when it was before.
  static func redactingExpansions(in text: String, using shortcuts: [TextShortcut]) -> String {
    var result = text
    for shortcut in shortcuts.sorted(by: { $0.expansion.count > $1.expansion.count }) {
      let expansion = shortcut.expansion
      result = result.replacingOccurrences(of: expansion, with: shortcut.trigger)
      let clip = stride(from: expansion.count - 1, through: minimumClippedOverlap, by: -1)
        .lazy.map { String(expansion.suffix($0)) }
        .first(where: result.hasPrefix)
      if let clip {
        result = shortcut.trigger + result.dropFirst(clip.count)
      }
    }
    return result
  }

  private static func matchesWhole(_ text: String, pattern: String) -> Bool {
    guard !text.isEmpty,
      let regex = try? NSRegularExpression(pattern: "^\(pattern)$", options: [.caseInsensitive])
    else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }
}
