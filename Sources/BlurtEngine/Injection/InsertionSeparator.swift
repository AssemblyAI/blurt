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
  public static func withLeadingSeparator(_ text: String, after priorText: String?) -> String {
    guard !text.isEmpty else { return text }
    guard let priorText, let last = priorText.last, !last.isWhitespace else { return text }
    guard let first = text.first, !first.isWhitespace else { return text }
    return " " + text
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
