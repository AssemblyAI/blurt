import AppKit
import Foundation
import Testing

@testable import BlurtEngine

/// Exercises `KeyInjector.insert` and its clipboard save/restore. The real Cmd-V
/// poster is replaced with an injected closure so no keystroke is sent to the
/// focused app, and an in-memory `FakeClipboard` stands in for the system
/// pasteboard so the save/restore + changeCount logic is tested in full
/// isolation — no dependency on (or races with) the host's real clipboard.
@Suite("KeyInjector.insert")
struct KeyInjectorInsertTests {

  @Test("restores the prior pasteboard contents after pasting")
  func restoresClipboard() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    let injector = KeyInjector(pasteSettleDuration: .zero, postPaste: { true }, clipboard: clip)
    try await injector.insert("dictated text")
    // The restore is deferred to the background settle task; await it before
    // asserting the user's clipboard came back.
    await injector.pendingSettle?.value

    #expect(clip.string == "user-clipboard")
  }

  @Test("insert returns before the deferred clipboard restore runs")
  func deferRestoreReArmsEarly() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    // A 1s settle: long enough that the assertions below run well before the
    // background restore fires, so the "still pending" checks are deterministic.
    let injector = KeyInjector(
      pasteSettleDuration: .seconds(1), postPaste: { true }, clipboard: clip)

    try await injector.insert("dictated text")

    // insert() has returned, but the restore is deferred: the pasted text is
    // still on the clipboard and a settle task is in flight. This is what lets
    // the pipeline re-arm immediately instead of waiting out the settle.
    let settle = await injector.pendingSettle
    #expect(clip.string == "dictated text")
    #expect(settle != nil)

    // The backgrounded settle eventually restores the user's clipboard.
    await settle?.value
    #expect(clip.string == "user-clipboard")
  }

  @Test("activates a live target app before pasting")
  func activatesTargetApp() async throws {
    let activated = ValueBox<Bool>(false)
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: { true },
      activateTarget: { _ in
        activated.set(true)
        return true
      },
      clipboard: FakeClipboard(string: nil))
    await injector.setTargetApp(try liveTargetApp())
    try await injector.insert("dictated text")  // must not throw
    #expect(activated.value)
  }

  @Test("activation failure: skips the paste but leaves the transcript on the clipboard")
  func activationFailureSkipsPaste() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    let posted = ValueBox<Bool>(false)
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set(true)
        return true
      },
      activateTarget: { _ in false },
      clipboard: clip)
    await injector.setTargetApp(try liveTargetApp())

    await #expect(throws: BlurtError.targetAppLost) {
      try await injector.insert("text")
    }
    // No ⌘V was posted into whatever now has focus, but the transcript survives
    // on the clipboard so the failure degrades to a "copied" notice.
    #expect(posted.value == false)
    #expect(clip.string == "text")
  }

  @Test("empty text is a no-op (no paste posted)")
  func emptyTextNoOp() async throws {
    let posted = ValueBox<Bool>(false)
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set(true)
        return true
      })
    try await injector.insert("")
    #expect(posted.value == false)
  }

  @Test("paste synthesis failure: throws .targetAppLost, transcript stays on the clipboard")
  func pasteSynthesisFailureThrows() async {
    let clip = FakeClipboard(string: "user-clipboard")
    let injector = KeyInjector(pasteSettleDuration: .zero, postPaste: { false }, clipboard: clip)
    await #expect(throws: BlurtError.targetAppLost) {
      try await injector.insert("text")
    }
    // The paste never happened, so the transcript is deliberately left on the
    // clipboard (not restored away) — the user's words beat the stale snapshot.
    #expect(clip.string == "text")
  }

  @Test("throws .accessibilityPermissionMissing and leaves the clipboard untouched")
  func notAccessibilityTrustedThrows() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    let posted = ValueBox<Bool>(false)
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set(true)
        return true
      },
      isAccessibilityTrusted: { false },
      clipboard: clip)

    await #expect(throws: BlurtError.accessibilityPermissionMissing) {
      try await injector.insert("text")
    }
    // No paste posted, and the user's clipboard is left exactly as it was.
    #expect(posted.value == false)
    #expect(clip.string == "user-clipboard")
  }

  @Test("no editable target: skips the paste and leaves the transcript on the clipboard")
  func noEditableTargetKeepsClipboard() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    let posted = ValueBox<Bool>(false)
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set(true)
        return true
      },
      hasEditableTarget: { false },
      clipboard: clip)

    await #expect(throws: BlurtError.noEditableTarget) {
      try await injector.insert("dictated text")
    }
    // No ⌘V was posted (so macOS never beeps), and the transcript is left on the
    // clipboard for a manual paste rather than being restored away.
    #expect(posted.value == false)
    #expect(clip.string == "dictated text")
  }

  @Test("AX-opaque Electron editor still pastes despite no editable signal")
  func electronEditorPastesWithoutSignal() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    let posted = ValueBox<Bool>(false)
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set(true)
        return true
      },
      hasEditableTarget: { false },  // Electron/Chromium exposes no editable AX signal
      isAXOpaqueEditor: { _ in true },  // …but it *is* an Electron editor
      clipboard: clip)

    // Must not throw noEditableTarget: the Electron exception keeps the paste.
    try await injector.insert("dictated text")
    await injector.pendingSettle?.value

    // The ⌘V was posted (words pasted, not copy-only), and the user's clipboard
    // is restored after the settle.
    #expect(posted.value == true)
    #expect(clip.string == "user-clipboard")
  }

  @Test("opaque editor: a second dictation into the same window gets a separating space")
  func opaqueEditorSameWindowInsertsSeparated() async throws {
    let clip = FakeClipboard(string: nil)
    // Record the text that actually lands on the pasteboard at each ⌘V (captured
    // inside `postPaste`, after `setString` and before the restore).
    let pasted = StringListBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        pasted.append(clip.string)
        return true
      },
      clipboard: clip)
    // Same target app AND window title for both dictations — e.g. two
    // back-to-back dictations into the same VS Code file, or the same Google
    // Docs tab. Prior text is nil because both surfaces are Accessibility-opaque.
    await injector.setTargetApp(try liveTargetApp())

    try await injector.insert("First.", after: nil, windowTitle: "notes.txt — Editor")
    try await injector.insert("Second.", after: nil, windowTitle: "notes.txt — Editor")

    // First paste lands as-is; the second is separated from it even though AX
    // gave us no prior text — the injector remembers what it just pasted into
    // this same window.
    #expect(pasted.values == ["First.", " Second."])
  }

  @Test("opaque editor: no phantom space when the window title changes (a tab/file switch)")
  func opaqueEditorDifferentWindowTitleNoSeparator() async throws {
    let clip = FakeClipboard(string: nil)
    let pasted = StringListBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        pasted.append(clip.string)
        return true
      },
      clipboard: clip)
    // Same target PID for both dictations (one browser process, or one Electron
    // window), but the window title changes between them — a different browser
    // tab (e.g. switching from Gmail to a fresh Google Docs tab) or a different
    // file in the same editor. A shared PID alone must not be enough to carry a
    // leading space into what is really a different field.
    await injector.setTargetApp(try liveTargetApp())

    try await injector.insert("First.", after: nil, windowTitle: "Inbox — Gmail")
    try await injector.insert("Second.", after: nil, windowTitle: "Untitled document — Google Docs")

    #expect(pasted.values == ["First.", "Second."])
  }

  @Test("opaque editor: no phantom space when no window title is available")
  func opaqueEditorNoWindowTitleNoSeparator() async throws {
    let clip = FakeClipboard(string: nil)
    let pasted = StringListBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        pasted.append(clip.string)
        return true
      },
      clipboard: clip)
    // Same target PID, but neither dictation could read a window title — can't
    // confirm it's really the same window, so the fallback stays off rather
    // than guessing.
    await injector.setTargetApp(try liveTargetApp())

    try await injector.insert("First.", after: nil)
    try await injector.insert("Second.", after: nil)

    #expect(pasted.values == ["First.", "Second."])
  }

  @Test("opaque editor: no phantom space after the target app changes")
  func opaqueEditorDifferentTargetNoSeparator() async throws {
    let clip = FakeClipboard(string: nil)
    let pasted = StringListBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        pasted.append(clip.string)
        return true
      },
      clipboard: clip)
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.processIdentifier > 0 && !$0.isTerminated
    }
    try #require(apps.count >= 2)

    await injector.setTargetApp(apps[0])
    try await injector.insert("First.", after: nil)
    await injector.setTargetApp(apps[1])
    try await injector.insert("Second.", after: nil)

    // The second paste targets a different app, so the remembered text from the
    // first must not bleed across as a leading space.
    #expect(pasted.values == ["First.", "Second."])
  }

  @Test("overlapping inserts still restore the user's original clipboard")
  func overlappingInsertsRestoreOriginal() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    // A non-zero settle keeps insert #1's backgrounded settle task holding the
    // paste lock while a second insert arrives. Without serialization, insert #2
    // would snapshot the clipboard while it still holds insert #1's "first" text
    // and later restore *that* instead of the user's original. `postPaste` opens
    // the gate while #1 still holds the lock (insert #1 then hands the lock to
    // its settle task and returns), so when `wait()` returns insert #2
    // deterministically blocks on the lock until #1's settle restores and
    // releases — rather than interleaving. No timing margin needed.
    let firstParked = AsyncGate()
    let injector = KeyInjector(
      pasteSettleDuration: .milliseconds(100),
      postPaste: {
        firstParked.open()
        return true
      },
      clipboard: clip)

    let first = Task { try await injector.insert("first") }
    await firstParked.wait()
    try await injector.insert("second")
    try await first.value
    // Await the second insert's deferred settle (insert returns before it runs).
    await injector.pendingSettle?.value

    #expect(clip.string == "user-clipboard")
  }

  @Test("a copy during the settle window is preserved, not clobbered by restore")
  func copyDuringSettleIsPreserved() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    // The paste posts, then the deferred settle waits. During that wait the user
    // copies something new. The restore must not blow that away with the stale
    // pre-paste snapshot — once the pasteboard changed under us, the right move
    // is to leave the newer contents alone.
    let pasted = AsyncGate()
    let injector = KeyInjector(
      pasteSettleDuration: .milliseconds(100),
      postPaste: {
        pasted.open()
        return true
      },
      clipboard: clip)

    let task = Task { try await injector.insert("dictated") }
    await pasted.wait()
    clip.externalWrite("copied-mid-paste")
    try await task.value
    // Await the deferred settle: it must see the changed changeCount and skip the
    // restore, leaving the user's mid-paste copy intact.
    await injector.pendingSettle?.value

    #expect(clip.string == "copied-mid-paste")
  }

  @Test("a cancelled task throws before posting any paste")
  func cancelledBeforePaste() async throws {
    let posted = ValueBox<Bool>(false)
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set(true)
        return true
      })
    // Gate the body so `cancel()` is guaranteed to land before `insert` reaches
    // its first cancellation check. Without this, a busy machine can run the
    // task past that check before `cancel()` arrives, posting the paste and
    // flaking the assertion. The gate opens only after the cancel.
    let gate = AsyncGate()
    let task = Task {
      await gate.wait()
      try await injector.insert("text")
    }
    task.cancel()
    gate.open()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(posted.value == false)
  }
}

// The shared fixtures these tests drive the injector with — `liveTargetApp`,
// `AsyncGate`, `StringListBox`, `ValueBox` — live in `Stubs/InjectorTestSupport.swift`
// so the fallback/cancel suite (a separate file) can reuse them.
