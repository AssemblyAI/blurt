// periphery:ignore - public for the iOS keyboard (App/BlurtiOS), which the Mac scan doesn't index.
/// The pure text rules for joining a new dictation onto whatever already sits
/// before the caret.
///
/// Shared by `KeyInjector` — the macOS clipboard paste — and by any host that
/// inserts text itself: an iPhone keyboard writing the transcript through
/// `insertText` faces exactly this decision, with `documentContextBeforeInput`
/// as the prior text. So it lives on its own type with no platform imports
/// rather than as `KeyInjector`'s extension (where it started; the tests moved
/// with it). `KeyInjector.resolveInsert` composes these two with the
/// window-identity decision, which stays beside the actor's state.
public enum InsertionSeparator {
  // periphery:ignore - public for the iOS keyboard (App/BlurtiOS), which the Mac scan doesn't index.
  /// Joins `text` to whatever precedes the caret with exactly one separating space,
  /// so consecutive dictations don't run together. Prepends a *leading* space only
  /// when there's preceding text (`priorText`) that doesn't already end in
  /// whitespace; leaves `text` untouched for an empty/unknown field or when the
  /// caret already follows whitespace.
  ///
  /// A leading separator beats a trailing one: a trailing space dangles at the end
  /// of a paste where many text engines trim or collapse it (so the next paste
  /// abuts the previous text), whereas a leading space lands *between* the two
  /// chunks where nothing strips it. `priorText` is nil for empty fields and for
  /// secure/Accessibility-opaque fields — there we can't tell what precedes the
  /// caret, so we add no separator rather than risk a stray leading space.
  ///
  /// Nor after an *opener* — a character that binds to the word typed after it
  /// (see `endsInOpener`): `Call me (` + "maybe" pastes `Call me (maybe`, not
  /// `Call me ( maybe`.
  public static func withLeadingSeparator(_ text: String, after priorText: String?) -> String {
    guard !text.isEmpty else { return text }
    guard let priorText, let last = priorText.last, !last.isWhitespace else { return text }
    guard let first = text.first, !first.isWhitespace else { return text }
    guard !endsInOpener(priorText) else { return text }
    return " " + text
  }

  /// Characters that always open what follows them, so a dictation after one
  /// joins with no space: brackets, the typographic *opening* quotes and
  /// guillemet, Spanish inverted marks, and the mention and currency prefixes.
  /// Deliberately conservative — `/` and `-` are left out because
  /// `yes /` or `well -` can just as well want the space as not.
  private static let openers: Set<Character> = [
    "(",
    "[",
    "{",
    "\u{201C}",
    "\u{2018}",
    "\u{00AB}",
    "\u{00BF}",
    "\u{00A1}",
    "@",
    "$",
  ]

  /// Characters that open only at the start of a word — the start of the text
  /// or after whitespace. Straight quotes both open and close (`said "` opens,
  /// `said "hi"` closes), and `#` after a word is a suffix (`C#`, `F#`), not a
  /// hashtag.
  private static let wordStartOpeners: Set<Character> = ["\"", "'", "#"]

  /// Whether `priorText` ends in a character the next word should abut.
  static func endsInOpener(_ priorText: String) -> Bool {
    guard let last = priorText.last else { return false }
    if openers.contains(last) { return true }
    guard wordStartOpeners.contains(last) else { return false }
    return priorText.dropLast().last?.isWhitespace ?? true
  }

  /// Chooses what text the separator decision should treat as preceding the
  /// caret. AX-read `priorText` is authoritative whenever we have it. When it's
  /// nil — the field is empty *or* Accessibility-opaque (Electron/Monaco, e.g. VS
  /// Code — or a browser tab like Google Docs, whose canvas-rendered body is just
  /// as opaque) — we can't tell those apart from AX alone, so we fall back to the
  /// text we last pasted, but only when this dictation targets the *same window*
  /// as last time (see `KeyInjector.WindowIdentity`): that's the in-progress-run
  /// case where our own paste is what now sits before the caret. This is
  /// deliberately app-agnostic rather than an allowlist of "known opaque
  /// editors": a window match is a reasonable proxy for "still the same document"
  /// across *any* app, opaque or not, whereas a shared process id alone isn't
  /// (one browser process hosts many unrelated tabs/documents). Otherwise (a
  /// different window or nothing pasted yet) we return nil rather than risk a
  /// stray leading space into what may be a genuinely fresh field.
  static func basis(priorText: String?, lastInserted: String?, sameWindow: Bool) -> String? {
    if priorText != nil { return priorText }
    return sameWindow ? lastInserted : nil
  }
}
