// The half of `FocusCapture` that decides things *without* making an
// Accessibility call, split out of `FocusCapture.swift` to stay within the lint
// file-length budget — cut on the seam the section was already marked with, since
// "no AX I/O" is exactly what makes these unit-testable in isolation while
// `captureFieldContext` and the attribute reads beside it need a live
// `AXUIElement` in a trusted process. The AX-touching editability probes live in
// `FocusCapture+Editability.swift`.
//
// Deliberately importless: this is all Swift stdlib (String/Unicode.Scalar), so
// even `Foundation` would be an unused import.
extension FocusCapture {
  /// The AX role password inputs report. `captureFieldContext` never reads the
  /// prior/selected text of a field with this role into the STT request, so a
  /// typed password can't leak. Independent of editability: the same role is in
  /// `editableRoles`, so a password field still *receives* the paste.
  static let secureFieldRole = "AXSecureTextField"

  /// The whole password-redaction decision `captureFieldContext` acts on: may this
  /// focused element's contents be read into the STT request at all?
  ///
  /// Fails **closed** on an unreadable role (an AX timeout against a busy app, a
  /// non-string value from a buggy one): we can't prove the field isn't secure, so
  /// treat it as secure. The cost of failing closed is losing priming for an
  /// already-degraded app; the cost of failing open is a password in an outbound
  /// API request — and, with developer mode on, in `dictations.jsonl`.
  ///
  /// This lives here, whole, rather than as `role == nil || isSecureField(…)` at
  /// the call site: `captureFieldContext` needs a live `AXUIElement`, so a decision
  /// made inline there is covered by no test, and `isSecureField(role: nil,
  /// subrole: nil)` is deliberately `false` — a test pins that. Splitting the
  /// verdict across a tested half and an untested half is how a fail-closed guard
  /// gets "simplified" away with the suite still green.
  static func mustRedactContents(role: String?, subrole: String?) -> Bool {
    role == nil || isSecureField(role: role, subrole: subrole)
  }

  /// Whether an element's role/subrole *identify* it as a secure field. Note this
  /// answers only that narrower question — `mustRedactContents` is the guard
  /// `captureFieldContext` uses, because an unreadable role must redact too.
  static func isSecureField(role: String?, subrole: String?) -> Bool {
    // AppKit ships both NSAccessibilitySecureTextFieldRole and
    // NSAccessibilitySecureTextFieldSubrole (both the same string), and an element
    // may report a generic `AXTextField` role while expressing secure-ness only
    // through its subrole — browser password inputs and custom secure fields are
    // the population that does this. Checking role alone misses them entirely.
    role == secureFieldRole || subrole == secureFieldRole
  }

  /// Collapses an AX text read that carries no *visible* content to `nil`.
  ///
  /// Google Docs (and some other web editors) expose the text before the caret as
  /// a lone U+200B ZERO WIDTH SPACE — invisible, not real content, yet crucially
  /// *not* `Character.isWhitespace`. Left as-is, `KeyInjector.withLeadingSeparator`
  /// reads it as substantive preceding text that doesn't end in whitespace and
  /// prepends a stray separator space on every dictation. Treating an
  /// entirely-invisible read as "nothing readable here" (`nil`) instead routes the
  /// field into the same-window separator fallback like any other
  /// Accessibility-opaque editor (see `KeyInjector.separatorBasis`).
  ///
  /// "Invisible" means every scalar is a default-ignorable code point (zero-width
  /// spaces, joiners, bidi marks, BOM, …). Regular whitespace (space/tab/newline)
  /// is deliberately preserved: a caret that already follows real whitespace must
  /// stay non-`nil` so the separator logic adds no extra space.
  static func visibleTextOrNil(_ text: String?) -> String? {
    guard let text else { return nil }
    let hasVisible = text.contains { character in
      !character.unicodeScalars.allSatisfy { $0.properties.isDefaultIgnorableCodePoint }
    }
    return hasVisible ? text : nil
  }

  /// Picks the most descriptive field label in priority order
  /// (placeholder → description → title → role description), skipping blanks.
  /// Placeholder/description tend to be the most meaningful; role description
  /// ("text entry area") is the generic last resort.
  ///
  /// The candidates are `@autoclosure`s so each is read only if the ones before it
  /// came back blank. `fieldLabel` passes AX attribute reads, and every one is a
  /// synchronous cross-process round trip bounded by
  /// `axMessagingTimeoutSeconds` — evaluated eagerly, a first-match-wins choice
  /// cost four timeouts against an unresponsive app where one would do, inside a
  /// capture whose whole design point is bounded cost. Call sites are unchanged:
  /// an autoclosure wraps the argument expression for them.
  static func selectLabel(
    placeholder: @autoclosure () -> String?,
    description: @autoclosure () -> String?,
    title: @autoclosure () -> String?,
    roleDescription: @autoclosure () -> String?
  ) -> String? {
    if let value = placeholder().trimmedNonEmpty() { return value }
    if let value = description().trimmedNonEmpty() { return value }
    if let value = title().trimmedNonEmpty() { return value }
    return roleDescription().trimmedNonEmpty()
  }

  /// The up-to-`maxChars` slice of `full` ending at `caret`. `caret` is a
  /// **UTF-16 offset** (the domain AX selected-text ranges use — see
  /// `caretLocation`), so it is resolved through the UTF-16 view rather than
  /// counted in `Character`s, which diverge as soon as the text holds emoji or
  /// other surrogate pairs. A caret outside the string — or one that doesn't
  /// land on a character boundary — falls back to the tail of the whole value.
  /// Returns `nil` when the resulting slice is empty.
  static func priorSlice(full: String, caret: Int, maxChars: Int) -> String? {
    guard !full.isEmpty else { return nil }
    let upto: Substring
    if caret >= 0, caret <= full.utf16.count,
      let index = full.utf16.index(
        full.utf16.startIndex, offsetBy: caret, limitedBy: full.utf16.endIndex)?
        .samePosition(in: full)
    {
      upto = full[..<index]
    } else {
      upto = full[...]
    }
    let clipped = String(upto.suffix(maxChars))
    return clipped.isEmpty ? nil : clipped
  }

  /// Caps `text` at `maxChars` characters (used to bound window titles / labels
  /// so an oddly long one can't dominate the context budget).
  static func clip(_ text: String?, to maxChars: Int) -> String? {
    guard let text, text.count > maxChars else { return text }
    return String(text.prefix(maxChars))
  }
}
