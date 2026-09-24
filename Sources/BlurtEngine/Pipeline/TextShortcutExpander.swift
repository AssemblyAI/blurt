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
  /// What counts as part of a word — the regex spelling of
  /// `CharacterSet.alphanumerics` (letters, marks, digits), which `words(in:)`
  /// splits on.
  private static let wordClass = "\\p{L}\\p{M}\\p{N}"

  /// Sentence punctuation: a break when whitespace follows it, and what the
  /// cleanup rewrite adds to a lone phrase ("Personal email.").
  private static let sentencePunctuation = ".,!?;:"

  /// What may sit between two of a trigger's words: any run of non-word
  /// characters, except sentence punctuation directly before whitespace, which
  /// is a break in the speech rather than part of a name.
  private static let separatorRun =
    "(?:[^\(wordClass)\(sentencePunctuation)]|[\(sentencePunctuation)](?!\\s))*"

  static func expand(_ text: String, using shortcuts: [TextShortcut]) -> String {
    // Longest first, so a trigger that extends another claims the text before
    // its prefix can. Group i+1 of `alternation` is `ordered[i]`.
    let ordered = shortcuts.compactMap { shortcut in pattern(for: shortcut.trigger).map { (shortcut, $0) } }
      .sorted { $0.1.count > $1.1.count }
    guard !ordered.isEmpty else { return text }
    let alternation = ordered.map { "(\($0.1))" }.joined(separator: "|")

    // A trigger standing alone — surrounding whitespace and closing punctuation
    // aside — becomes exactly its expansion: a trailing period glued to an
    // address or URL is never what someone dictating a snippet on its own
    // wanted. The whitespace is kept so the paste separator logic sees the same
    // shape.
    let source = text as NSString
    let whole = NSRange(location: 0, length: source.length)
    if let lone = regex("^(\\s*)(?:\(alternation))[\(sentencePunctuation)]*(\\s*)$")?
      .firstMatch(in: text, range: whole),
      let index = shortcutIndex(in: lone, groupOffset: 2, count: ordered.count)
    {
      return source.substring(with: lone.range(at: 1)) + ordered[index].0.expansion
        + source.substring(with: lone.range(at: ordered.count + 2))
    }

    guard let inline = regex("(?<![\(wordClass)])(?:\(alternation))(?![\(wordClass)])") else {
      return text
    }
    var result = ""
    var cursor = 0
    for match in inline.matches(in: text, range: whole) {
      guard let index = shortcutIndex(in: match, groupOffset: 1, count: ordered.count) else {
        continue
      }
      result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      result += ordered[index].0.expansion
      cursor = match.range.location + match.range.length
    }
    result += source.substring(from: cursor)
    return result
  }

  /// The trigger's letter/digit runs — the only part of it the matcher reads.
  static func words(in trigger: String) -> [String] {
    trigger.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
  }

  /// `text` with every expansion in it put back to its trigger — the inverse of
  /// `expand`, for the text before the caret that `STTPrompt` sends. After a
  /// shortcut is pasted the field *holds* the saved replacement, and the next
  /// press reads it back; this keeps it local.
  ///
  /// Literal and case-sensitive, since the field holds exactly what was pasted.
  /// Longest expansion first, so one that contains another is caught whole. The
  /// capture reads only the last few hundred characters, so a long expansion can
  /// arrive with its head cut off: a tail of one (at least
  /// `minimumClippedOverlap` long) at the very start of `text` counts too.
  /// Replaced with the trigger rather than nothing, so the prompt still reads as
  /// the continuous passage it is.
  static func redactingExpansions(in text: String, using shortcuts: [TextShortcut]) -> String {
    var result = text
    for shortcut in shortcuts.sorted(by: { $0.expansion.count > $1.expansion.count }) {
      let expansion = shortcut.expansion
      result = result.replacingOccurrences(of: expansion, with: shortcut.trigger)
      // No clip longer than `result` can be its prefix, so start there.
      let longest = min(expansion.count - 1, result.count)
      if let clip = stride(from: longest, through: minimumClippedOverlap, by: -1).lazy
        .map({ expansion.suffix($0) }).first(where: { result.hasPrefix($0) })
      {
        result = shortcut.trigger + result.dropFirst(clip.count)
      }
    }
    return result
  }

  /// The fewest characters of an expansion's tail that `redactingExpansions`
  /// treats as a clipped copy at the very start of `text`. Below this an overlap
  /// is as likely to be coincidence — a shared "com" or "." — as a clip.
  private static let minimumClippedOverlap = 4

  /// The regex body for one trigger: its letter/digit runs, escaped, joined by
  /// an optional run of separators. `nil` for a trigger with no letters or
  /// digits, which could only ever match punctuation.
  private static func pattern(for trigger: String) -> String? {
    let words = words(in: trigger)
    guard !words.isEmpty else { return nil }
    return words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: separatorRun)
  }

  /// Which of the `count` trigger groups, numbered from `groupOffset`, took
  /// part in `match` — exactly one does.
  private static func shortcutIndex(
    in match: NSTextCheckingResult, groupOffset: Int, count: Int
  ) -> Int? {
    (0..<count).first { match.range(at: $0 + groupOffset).location != NSNotFound }
  }

  private static func regex(_ pattern: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }
}
