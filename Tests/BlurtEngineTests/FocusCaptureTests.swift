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
}
