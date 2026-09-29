// Foundation for `pid_t`: the resolve-insert suite below names it, and the two
// pure text-rule suites this file started as needed no imports at all.
import Foundation
import Testing

@testable import BlurtEngine

@Suite("KeyInjector.withLeadingSeparator")
struct KeyInjectorLeadingSeparatorTests {
  @Test("prepends a space when prior text doesn't end in whitespace")
  func prependsSpace() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.") == " Second.")
  }

  @Test("no separator when prior text already ends in a space")
  func priorEndsInSpace() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First. ") == "Second.")
  }

  @Test("no separator when prior text ends in a newline")
  func priorEndsInNewline() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.\n") == "Second.")
  }

  @Test("no leading space into an empty field (nil prior text)")
  func nilPrior() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: nil) == "Second.")
  }

  @Test("no leading space when prior text is empty")
  func emptyPrior() {
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "") == "Second.")
  }

  @Test("doesn't double up when the new text already starts with whitespace")
  func textStartsWithSpace() {
    #expect(KeyInjector.withLeadingSeparator(" Second.", after: "First.") == " Second.")
  }

  @Test("returns empty text unchanged")
  func emptyText() {
    #expect(KeyInjector.withLeadingSeparator("", after: "First.") == "")
  }

  @Test("every whitespace class counts, not just space and newline")
  func otherWhitespaceClasses() {
    // The rules key on Character.isWhitespace: a trailing tab, carriage return,
    // or non-breaking space suppresses the separator like a plain space does…
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.\t") == "Second.")
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.\r") == "Second.")
    #expect(KeyInjector.withLeadingSeparator("Second.", after: "First.\u{00A0}") == "Second.")
    // …and text already leading with a tab or non-breaking space isn't doubled.
    #expect(KeyInjector.withLeadingSeparator("\tSecond.", after: "First.") == "\tSecond.")
    #expect(KeyInjector.withLeadingSeparator("\u{00A0}Second.", after: "First.") == "\u{00A0}Second.")
  }
}

@Suite("KeyInjector.separatorBasis")
struct KeyInjectorSeparatorBasisTests {
  @Test("AX-read prior text wins even when a prior paste is on record")
  func priorTextWins() {
    #expect(
      KeyInjector.separatorBasis(priorText: "AX.", lastInserted: "Old.", sameWindow: false) == "AX.")
  }

  @Test("falls back to the last paste when AX is opaque and the window is unchanged")
  func opaqueSameWindowFallsBack() {
    #expect(
      KeyInjector.separatorBasis(priorText: nil, lastInserted: "First.", sameWindow: true)
        == "First.")
  }

  @Test("does not carry a prior paste across a different window")
  func opaqueDifferentWindowNoFallback() {
    #expect(
      KeyInjector.separatorBasis(priorText: nil, lastInserted: "First.", sameWindow: false) == nil)
  }

  @Test("no basis when AX is opaque and nothing was pasted yet")
  func opaqueNoPriorPaste() {
    #expect(KeyInjector.separatorBasis(priorText: nil, lastInserted: nil, sameWindow: true) == nil)
  }
}

/// `resolveInsert` — everything `performInsert` decides before it activates
/// anything: the text to write and the window to remember writing it into. The
/// same-window derivation used to be inline in `performInsert`, so these cases
/// could only be driven by scraping `NSWorkspace` for live applications (and one
/// of them by requiring two). Here the target is just a pid.
@Suite("KeyInjector.resolveInsert")
struct KeyInjectorResolveInsertTests {
  private let editor = KeyInjector.WindowIdentity(pid: 501, title: "notes.txt — Editor")

  /// A second dictation with no AX prior text, resolved against `editor`.
  private func secondInsert(
    targetPID: pid_t?, windowTitle: String?, priorText: String? = nil
  ) -> KeyInjector.ResolvedInsert {
    KeyInjector.resolveInsert(
      text: "Second.", priorText: priorText, windowTitle: windowTitle, targetPID: targetPID,
      lastInserted: KeyInjector.ResolvedInsert(text: "First.", window: editor))
  }

  @Test("opaque editor: the same pid and title recovers the spacing from the last paste")
  func sameWindowSeparates() {
    // Two back-to-back dictations into the same VS Code file or Google Docs tab:
    // AX gives no prior text, so what we pasted a moment ago is what precedes
    // the caret.
    #expect(
      secondInsert(targetPID: editor.pid, windowTitle: editor.title)
        == KeyInjector.ResolvedInsert(text: " Second.", window: editor))
  }

  @Test("opaque editor: a changed title is a different field, so no phantom space")
  func changedTitleDoesNotSeparate() {
    // One browser process (or one Electron window) but a different tab or file —
    // a shared pid alone must not carry spacing into an unrelated document. The
    // new window is still remembered, so a *third* dictation into it separates.
    let resolved = secondInsert(targetPID: editor.pid, windowTitle: "Untitled document — Docs")
    #expect(resolved.text == "Second.")
    #expect(resolved.window == KeyInjector.WindowIdentity(pid: editor.pid, title: "Untitled document — Docs"))
  }

  @Test("no readable window title means no match and nothing to remember")
  func missingTitleDoesNotSeparate() {
    // Can't confirm it's the same window, so the fallback stays off rather than
    // guessing — and with no identity to record, the next dictation can't match
    // this one either.
    #expect(
      secondInsert(targetPID: editor.pid, windowTitle: nil)
        == KeyInjector.ResolvedInsert(text: "Second.", window: nil))
  }

  @Test("a different target app never inherits the previous paste's spacing")
  func changedTargetDoesNotSeparate() {
    let resolved = secondInsert(targetPID: 777, windowTitle: editor.title)
    #expect(resolved.text == "Second.")
    #expect(resolved.window == KeyInjector.WindowIdentity(pid: 777, title: editor.title))
  }

  @Test("no captured target at all: nothing to match, nothing to remember")
  func noTargetDoesNotSeparate() {
    #expect(
      secondInsert(targetPID: nil, windowTitle: editor.title)
        == KeyInjector.ResolvedInsert(text: "Second.", window: nil))
  }

  @Test("AX prior text wins over the remembered paste, in the same window or not")
  func priorTextWinsOverMemory() {
    // The field is readable, so the caret's real neighbour decides — here it
    // already ends in whitespace, which the remembered "First." would not have.
    #expect(secondInsert(targetPID: editor.pid, windowTitle: editor.title, priorText: "Hello ").text == "Second.")
    #expect(secondInsert(targetPID: 777, windowTitle: "Other", priorText: "Hello").text == " Second.")
  }

  @Test("a first-ever insert has no memory to fall back on")
  func firstInsertHasNoBasis() {
    let resolved = KeyInjector.resolveInsert(
      text: "First.", priorText: nil, windowTitle: editor.title, targetPID: editor.pid,
      lastInserted: nil)
    #expect(resolved == KeyInjector.ResolvedInsert(text: "First.", window: editor))
  }
}
