import Testing

@testable import BlurtEngine

/// Covers the pure decision logic `FocusCapture` applies to values read from the
/// Accessibility API. The AX reads themselves (`captureFieldContext` and the
/// `AXUIElementCopyAttributeValue` wrappers) require a live focused UI and
/// Accessibility trust, so they're exercised by running the app, not here.
@Suite("FocusCapture helpers")
struct FocusCaptureTests {
  // MARK: selectLabel

  @Test("selectLabel prefers placeholder when present")
  func labelPrefersPlaceholder() {
    let label = FocusCapture.selectLabel(
      placeholder: "Search", description: "desc", title: "title", roleDescription: "text field")
    #expect(label == "Search")
  }

  @Test("selectLabel falls through blanks in priority order")
  func labelFallsThrough() {
    let label = FocusCapture.selectLabel(
      placeholder: "  ", description: nil, title: "Subject", roleDescription: "text field")
    #expect(label == "Subject")
  }

  @Test("selectLabel uses role description only as a last resort")
  func labelRoleDescriptionLast() {
    let label = FocusCapture.selectLabel(
      placeholder: nil, description: nil, title: nil, roleDescription: "text entry area")
    #expect(label == "text entry area")
  }

  @Test("selectLabel returns nil when every candidate is blank")
  func labelAllBlank() {
    #expect(FocusCapture.selectLabel(placeholder: " ", description: "", title: nil, roleDescription: nil) == nil)
  }

  @Test("selectLabel trims the chosen candidate")
  func labelTrims() {
    let label = FocusCapture.selectLabel(
      placeholder: "  To  ", description: nil, title: nil, roleDescription: nil)
    #expect(label == "To")
  }

  @Test("selectLabel stops reading candidates once one answers")
  func labelIsLazy() {
    // `fieldLabel` passes AX attribute reads as the candidates, and each is a
    // synchronous cross-process round trip. First-match-wins must therefore also
    // mean first-match-only: pinned here so a refactor back to eager arguments
    // (e.g. collecting them into an array) fails instead of quietly costing three
    // extra AX timeouts per capture against an unresponsive app.
    var reads: [String] = []
    func read(_ attribute: String, _ value: String?) -> String? {
      reads.append(attribute)
      return value
    }
    let label = FocusCapture.selectLabel(
      placeholder: read("placeholder", "Search"),
      description: read("description", "desc"),
      title: read("title", "title"),
      roleDescription: read("roleDescription", "text field"))
    #expect(label == "Search")
    #expect(reads == ["placeholder"])
  }

  // MARK: priorSlice

  @Test("priorSlice returns text up to the caret")
  func priorUpToCaret() {
    #expect(FocusCapture.priorSlice(full: "hello world", caret: 5, maxChars: 320) == "hello")
  }

  @Test("priorSlice keeps only the trailing maxChars before the caret")
  func priorClipsToMax() {
    #expect(FocusCapture.priorSlice(full: "abcdef", caret: 6, maxChars: 3) == "def")
  }

  @Test("priorSlice with a caret out of range falls back to the value's tail")
  func priorCaretOutOfRange() {
    // caret == -1 (unreadable selection): use the tail of the whole value.
    #expect(FocusCapture.priorSlice(full: "abcdef", caret: -1, maxChars: 3) == "def")
    // caret < -1: same fallback.
    #expect(FocusCapture.priorSlice(full: "abcdef", caret: -5, maxChars: 3) == "def")
    // caret past the end: same fallback.
    #expect(FocusCapture.priorSlice(full: "abcdef", caret: 99, maxChars: 10) == "abcdef")
  }

  @Test("priorSlice returns nil for an empty value or a zero-length prefix")
  func priorEmpty() {
    #expect(FocusCapture.priorSlice(full: "", caret: 0, maxChars: 320) == nil)
    // caret at 0 → empty prefix → nil (nothing precedes the cursor).
    #expect(FocusCapture.priorSlice(full: "hello", caret: 0, maxChars: 320) == nil)
  }

  @Test("priorSlice is given the raw value, so surrounding whitespace keeps caret offsets valid")
  func priorSliceUntrimmedValue() {
    // These are the two cases that broke while the caller trimmed the value before
    // slicing it with an untrimmed caret offset (see `rawStringValue`).
    //
    // Trailing whitespace: "Hello " with the caret at 6 must yield "Hello " — the
    // trailing space is exactly what `withLeadingSeparator` reads to decide it must
    // NOT add another one. Trimmed to "Hello" (5 units), 6 > 5 fell through to the
    // whole-value tail "Hello", so the separator was added and the field got
    // "Hello  world".
    #expect(FocusCapture.priorSlice(full: "Hello ", caret: 6, maxChars: 320) == "Hello ")
    // Leading whitespace (an indented editor line): the caret at 8 in
    // "  Hello world" is just past "  Hello ". Trimmed to "Hello world" the slice
    // *succeeded* and returned "Hello wo" — text from AFTER the caret.
    #expect(FocusCapture.priorSlice(full: "  Hello world", caret: 8, maxChars: 320) == "  Hello ")
    // A value that is only whitespace still has a real prefix before the caret.
    #expect(FocusCapture.priorSlice(full: "   ", caret: 2, maxChars: 320) == "  ")
  }

  @Test("priorSlice treats the caret as a UTF-16 offset, not a Character count")
  func priorCaretIsUTF16() {
    // AX selected-text ranges are UTF-16: each emoji below is 2 UTF-16 units but
    // 1 Character, so a Character-counted prefix would over-reach past the caret.
    // Caret after the two emoji = offset 4.
    #expect(FocusCapture.priorSlice(full: "😀😀ab", caret: 4, maxChars: 320) == "😀😀")
    // Caret between the emoji = offset 2.
    #expect(FocusCapture.priorSlice(full: "😀😀ab", caret: 2, maxChars: 320) == "😀")
    // A caret that splits a surrogate pair isn't a character boundary — fall
    // back to the whole value's tail rather than slicing mid-character.
    #expect(FocusCapture.priorSlice(full: "😀b", caret: 1, maxChars: 320) == "😀b")
    // Offsets past the UTF-16 length keep the existing tail fallback.
    #expect(FocusCapture.priorSlice(full: "😀b", caret: 99, maxChars: 320) == "😀b")
  }

  // MARK: clip

  @Test("clip caps overlong text and passes short text through")
  func clipCaps() {
    #expect(FocusCapture.clip("abcdefghij", to: 4) == "abcd")
    #expect(FocusCapture.clip("abc", to: 4) == "abc")
    #expect(FocusCapture.clip(nil, to: 4) == nil)
  }

  // MARK: visibleTextOrNil

  @Test("visibleTextOrNil collapses an all-invisible AX read to nil")
  func visibleTextZeroWidthIsNil() {
    // Google Docs exposes its pre-caret text as a lone U+200B ZERO WIDTH SPACE —
    // invisible, not real content, and (crucially) NOT Character.isWhitespace, so
    // left as-is it drives a stray leading separator on every dictation. It must
    // read as "nothing here" so the field routes into the same-window fallback.
    #expect(FocusCapture.visibleTextOrNil("\u{200B}") == nil)
    #expect(FocusCapture.visibleTextOrNil("\u{200B}\u{200B}") == nil)
    // Other zero-width / format controls collapse too (BOM, bidi marks).
    #expect(FocusCapture.visibleTextOrNil("\u{FEFF}\u{200E}") == nil)
    #expect(FocusCapture.visibleTextOrNil("") == nil)
    #expect(FocusCapture.visibleTextOrNil(nil) == nil)
  }

  @Test("visibleTextOrNil keeps text with any visible content unchanged")
  func visibleTextKeepsRealContent() {
    #expect(FocusCapture.visibleTextOrNil("Hello") == "Hello")
    // A trailing zero-width alongside real text is preserved verbatim — there IS
    // visible content, so the read is real; only all-invisible reads collapse.
    #expect(FocusCapture.visibleTextOrNil("Hello\u{200B}") == "Hello\u{200B}")
  }

  @Test("visibleTextOrNil preserves plain whitespace")
  func visibleTextKeepsWhitespace() {
    // Regular spaces are NOT invisible-format: a caret that follows real
    // whitespace must stay non-nil so the separator logic sees the trailing space
    // and correctly adds no extra one (collapsing this to nil would wrongly route
    // into the fallback and prepend a space).
    #expect(FocusCapture.visibleTextOrNil("   ") == "   ")
    #expect(FocusCapture.visibleTextOrNil("hello ") == "hello ")
  }

  // MARK: isSecureField

  @Test("the password-field role triggers the prompt redaction")
  func secureFieldRoleDetection() {
    // The guard that keeps a typed password out of the STT prompt keys on this
    // exact role string — a rename or typo here would silently stop redacting.
    #expect(FocusCapture.isSecureField(role: "AXSecureTextField", subrole: nil))
    #expect(!FocusCapture.isSecureField(role: "AXTextField", subrole: nil))
    #expect(!FocusCapture.isSecureField(role: "AXTextArea", subrole: nil))
    #expect(!FocusCapture.isSecureField(role: nil, subrole: nil))
  }

  @Test("a secure *subrole* under a generic text role also redacts")
  func secureFieldSubroleDetection() {
    // AppKit exposes secure-ness as either a role or a subrole, and an element can
    // report a plain `AXTextField` role while only its subrole says "password" —
    // browser password inputs and custom secure fields do this. Keying on role
    // alone read those as ordinary text and sent their contents to the STT prompt.
    #expect(FocusCapture.isSecureField(role: "AXTextField", subrole: "AXSecureTextField"))
    #expect(FocusCapture.isSecureField(role: nil, subrole: "AXSecureTextField"))
    // A non-secure subrole must not redact an ordinary field.
    #expect(!FocusCapture.isSecureField(role: "AXTextField", subrole: "AXSearchField"))
  }

  // MARK: mustRedactContents

  @Test("an unreadable role redacts — the guard fails closed")
  func unreadableRoleRedacts() {
    // The case `isSecureField` deliberately answers `false` for (it identifies
    // secure fields, and a nil role identifies nothing). The guard
    // `captureFieldContext` actually consults must answer `true`: an AX read that
    // timed out or returned a non-string can't prove the field isn't a password, and
    // guessing wrong puts the typed password in an outbound request and, with
    // developer mode on, in dictations.jsonl.
    #expect(FocusCapture.mustRedactContents(role: nil, subrole: nil))
    #expect(FocusCapture.mustRedactContents(role: nil, subrole: "AXSearchField"))
    // Same verdict as `isSecureField` everywhere the role *is* readable.
    #expect(FocusCapture.mustRedactContents(role: "AXSecureTextField", subrole: nil))
    #expect(FocusCapture.mustRedactContents(role: "AXTextField", subrole: "AXSecureTextField"))
  }

  @Test("a readable, non-secure role does not redact — priming still works")
  func readableOrdinaryRoleDoesNotRedact() {
    // The other half of the contract: failing closed must not degrade into "never
    // read anything", which would silently drop prior-text priming everywhere.
    #expect(!FocusCapture.mustRedactContents(role: "AXTextField", subrole: nil))
    #expect(!FocusCapture.mustRedactContents(role: "AXTextArea", subrole: nil))
    #expect(!FocusCapture.mustRedactContents(role: "AXTextField", subrole: "AXSearchField"))
  }

  // MARK: isElectronApp

  @Test("isElectronApp is false for a missing app")
  func electronNilApp() {
    // The positive branch probes the app bundle on disk and is host-dependent;
    // the nil guard (no captured target → never the Electron paste exception)
    // is the deterministic half.
    #expect(!FocusCapture.isElectronApp(nil))
  }
}
