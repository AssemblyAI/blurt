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
    let activated = BoolBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: { true },
      activateTarget: { _ in
        activated.set()
        return true
      },
      clipboard: FakeClipboard(string: nil))
    await injector.setTargetApp(try liveTargetApp())
    try await injector.insert("dictated text")  // must not throw
    #expect(activated.value)
  }

  @Test("does not paste when the captured target app can't be activated")
  func activationFailureSkipsPaste() async throws {
    let posted = BoolBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set()
        return true
      },
      activateTarget: { _ in false })
    await injector.setTargetApp(try liveTargetApp())

    await #expect(throws: BlurtError.targetAppLost) {
      try await injector.insert("text")
    }
    #expect(posted.value == false)
  }

  @Test("empty text is a no-op (no paste posted)")
  func emptyTextNoOp() async throws {
    let posted = BoolBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set()
        return true
      })
    try await injector.insert("")
    #expect(posted.value == false)
  }

  @Test("throws .targetAppLost when the paste can't be synthesized")
  func pasteSynthesisFailureThrows() async {
    let clip = FakeClipboard(string: "user-clipboard")
    let injector = KeyInjector(pasteSettleDuration: .zero, postPaste: { false }, clipboard: clip)
    await #expect(throws: BlurtError.targetAppLost) {
      try await injector.insert("text")
    }
    #expect(clip.string == "user-clipboard")
  }

  @Test("throws .accessibilityPermissionMissing and leaves the clipboard untouched")
  func notAccessibilityTrustedThrows() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    let posted = BoolBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set()
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
    let posted = BoolBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set()
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
    let posted = BoolBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set()
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

  @Test("opaque editor: a second dictation into the same app gets a separating space")
  func opaqueEditorConsecutiveInsertsSeparated() async throws {
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
    // Same target app for both dictations (the VS Code case). Prior text is nil
    // because Electron/Monaco surfaces are Accessibility-opaque.
    await injector.setTargetApp(try liveTargetApp())

    try await injector.insert("First.", after: nil)
    try await injector.insert("Second.", after: nil)

    // First paste lands as-is; the second is separated from it even though AX
    // gave us no prior text — the injector remembers what it just pasted.
    #expect(pasted.values == ["First.", " Second."])
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
    let posted = BoolBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set()
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

private func liveTargetApp() throws -> NSRunningApplication {
  try #require(
    NSWorkspace.shared.runningApplications.first {
      $0.processIdentifier > 0 && !$0.isTerminated
    })
}

/// One-shot async gate: `wait()` suspends until `open()` is called. Tolerates
/// `open()` racing ahead of `wait()` (the waiter then returns immediately).
private final class AsyncGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var opened = false

  func wait() async {
    await withCheckedContinuation { cont in
      lock.lock()
      if opened {
        lock.unlock()
        cont.resume()
      } else {
        continuation = cont
        lock.unlock()
      }
    }
  }

  func open() {
    lock.lock()
    opened = true
    let cont = continuation
    continuation = nil
    lock.unlock()
    cont?.resume()
  }
}

/// Thread-safe ordered list of strings recorded inside a `@Sendable` closure,
/// for asserting the sequence of texts a test observed being pasted.
private final class StringListBox: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func append(_ value: String?) {
    lock.lock()
    items.append(value ?? "")
    lock.unlock()
  }
  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}

/// Thread-safe boolean flag for assertions inside a `@Sendable` closure.
private final class BoolBox: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  func set() {
    lock.lock()
    flag = true
    lock.unlock()
  }
  var value: Bool {
    lock.lock()
    defer { lock.unlock() }
    return flag
  }
}
