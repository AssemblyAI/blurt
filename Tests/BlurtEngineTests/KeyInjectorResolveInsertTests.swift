// Foundation for `pid_t`: the suite below names it.
import Foundation
import Testing

@testable import BlurtEngine

#if os(macOS)
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
        text: "Second.",
        priorText: priorText,
        windowTitle: windowTitle,
        targetPID: targetPID,
        lastInserted: KeyInjector.ResolvedInsert(text: "First.", window: editor)
      )
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
        text: "First.",
        priorText: nil,
        windowTitle: editor.title,
        targetPID: editor.pid,
        lastInserted: nil
      )
      #expect(resolved == KeyInjector.ResolvedInsert(text: "First.", window: editor))
    }
  }
#endif
