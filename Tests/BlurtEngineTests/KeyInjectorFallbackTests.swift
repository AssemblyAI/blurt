import AppKit
import Foundation
import Testing

@testable import BlurtEngine

/// Exercises `KeyInjector.insert`'s abort paths: the mid-activation cancel gate
/// and the copy-to-clipboard fallbacks. Split from `KeyInjectorInsertTests`
/// (same seams, same shared fixtures in `Stubs/InjectorTestSupport.swift`) to
/// stay within the lint file-length budget.
@Suite("KeyInjector.insert fallback & cancel")
struct KeyInjectorFallbackTests {

  @Test("a cancel landing during target activation aborts before the paste")
  func cancelDuringActivationSkipsPaste() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    let posted = ValueBox<Bool>(false)
    let insertTask = TaskBox()
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: {
        posted.set(true)
        return true
      },
      activateTarget: { _ in
        // The cancel lands while activation is in flight; activation itself
        // still succeeds, so only the post-activation cancellation gate stands
        // between the cancel and the irreversible ⌘V.
        insertTask.cancel()
        return true
      },
      clipboard: clip)
    await injector.setTargetApp(try liveTargetApp())

    // Park the insert behind a gate until the task handle is stored, so the
    // activation closure deterministically has something to cancel.
    let gate = AsyncGate()
    let task = Task {
      await gate.wait()
      try await injector.insert("text")
    }
    insertTask.set(task)
    gate.open()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    // No ⌘V was posted and the user's clipboard was never touched — the abort
    // happened before the save/overwrite stage.
    #expect(posted.value == false)
    #expect(clip.string == "user-clipboard")
  }

  @Test("the clipboard fallback carries the leading separator, not the raw text")
  func fallbackKeepsLeadingSeparator() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: { true },
      activateTarget: { _ in false },
      clipboard: clip)
    await injector.setTargetApp(try liveTargetApp())

    await #expect(throws: BlurtError.targetAppLost) {
      try await injector.insert("Second.", after: "First.")
    }
    // What lands on the clipboard is the final text a paste would have typed —
    // separator included — so a manual ⌘V still joins the prior text correctly.
    #expect(clip.string == " Second.")
  }

  @Test("a thrown insert releases the paste lock for the next dictation", .timeLimit(.minutes(1)))
  func failedInsertReleasesLock() async throws {
    let clip = FakeClipboard(string: "user-clipboard")
    let editable = ValueBox<Bool>(false)
    let injector = KeyInjector(
      pasteSettleDuration: .zero,
      postPaste: { true },
      hasEditableTarget: { editable.value },
      clipboard: clip)

    // First insert: nothing editable focused → copy fallback throws.
    await #expect(throws: BlurtError.noEditableTarget) {
      try await injector.insert("first")
    }

    // The throw path must have released the paste lock: a following insert
    // proceeds (rather than deadlocking behind a leaked lock, which the time
    // limit would surface) and completes a normal paste + deferred restore.
    editable.set(true)
    try await injector.insert("second")
    await injector.pendingSettle?.value
    // The restore brings back the pre-paste contents — which the failed insert
    // deliberately left as its copied transcript.
    #expect(clip.string == "first")
  }
}
