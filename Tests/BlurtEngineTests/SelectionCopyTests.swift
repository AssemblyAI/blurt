import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// An in-memory pasteboard. `postCopy` stands in for the target app answering
/// ⌘C by writing `copied` (nil models an app with nothing selected).
final class FakeCopyPasteboard: CopyPasteboard {
  struct State {
    var changeCount = 0
    var string: String? = "user's clipboard"
    var restoreCount = 0
    var ownWriteCount = 0
    /// A write the app makes just after its clear: applied the moment the
    /// cleared clipboard is first read, so the copier is guaranteed to see the
    /// clear on one poll and the write on a later one — without racing a timer.
    var lateWrite: String?
  }

  let state = Mutex(State())
  let readable: Bool

  init(readable: Bool = true) { self.readable = readable }

  var changeCount: Int { state.withLock(\.changeCount) }
  var ownWriteCount: Int { state.withLock(\.ownWriteCount) }
  func snapshot() -> PasteboardSnapshot? {
    guard readable else { return nil }
    return PasteboardSnapshot(items: [], plainText: state.withLock(\.string))
  }
  func currentString() -> String? {
    state.withLock {
      let current = $0.string
      if current == nil, let late = $0.lateWrite {
        $0.lateWrite = nil
        $0.string = late
        $0.changeCount += 1
      }
      return current
    }
  }
  func restore(_ saved: PasteboardSnapshot, ifChangeCountIs expected: Int) {
    state.withLock {
      guard $0.changeCount == expected else { return }
      $0.restoreCount += 1
      $0.string = saved.plainText
      $0.changeCount += 1
    }
  }

  /// Blurt writing the clipboard itself, as a paste does.
  func ownWrite(_ text: String) {
    state.withLock {
      $0.ownWriteCount += 1
      $0.string = text
      $0.changeCount += 1
    }
  }

  /// What the target app does on ⌘C.
  func answerCopy(with copied: String?) -> @Sendable () -> Bool {
    { [self] in
      if let copied {
        self.state.withLock {
          $0.string = copied
          $0.changeCount += 1
        }
      }
      return true
    }
  }

  var string: String? { state.withLock(\.string) }
  var restoreCount: Int { state.withLock(\.restoreCount) }
}

@Suite("SelectionCopy")
struct SelectionCopyTests {
  private func copy(_ pasteboard: FakeCopyPasteboard, answering copied: String?) -> SelectionCopy {
    SelectionCopy(pasteboard: pasteboard, postCopy: pasteboard.answerCopy(with: copied), timeout: .milliseconds(50))
  }

  @Test("returns what the ⌘C copied and puts the user's clipboard back")
  func copiesAndRestores() async {
    let pasteboard = FakeCopyPasteboard()
    let text = await copy(pasteboard, answering: "  The pre-push gate blocked it.  ").copySelection(maxCharacters: 100)
    #expect(text == "The pre-push gate blocked it.")
    #expect(pasteboard.string == "user's clipboard")
  }

  @Test("nothing copied means nothing selected — the clipboard is left untouched")
  func nothingCopied() async {
    let pasteboard = FakeCopyPasteboard()
    #expect(await copy(pasteboard, answering: nil).copySelection(maxCharacters: 100) == nil)
    #expect(pasteboard.restoreCount == 0)
  }

  @Test("an unreadable clipboard can't be restored, so no copy is attempted")
  func unreadableClipboard() async {
    let pasteboard = FakeCopyPasteboard(readable: false)
    let posted = Mutex(false)
    let copy = SelectionCopy(
      pasteboard: pasteboard,
      postCopy: {
        posted.withLock { $0 = true }
        return true
      })
    #expect(await copy.copySelection(maxCharacters: 100) == nil)
    #expect(!posted.withLock { $0 })
  }

  @Test("the copied text is capped like an Accessibility read")
  func capped() async {
    let pasteboard = FakeCopyPasteboard()
    #expect(await copy(pasteboard, answering: "abcdefgh").copySelection(maxCharacters: 3) == "abc")
  }

  @Test("a clear before the write isn't mistaken for an empty copy")
  func clearThenWrite() async {
    let pasteboard = FakeCopyPasteboard()
    // The app clears the clipboard (a change with no string), then writes the
    // selection a moment later.
    let copy = SelectionCopy(
      pasteboard: pasteboard,
      postCopy: {
        pasteboard.state.withLock {
          $0.string = nil
          $0.changeCount += 1
          $0.lateWrite = "late copy"
        }
        return true
      },
      timeout: .seconds(5))
    #expect(await copy.copySelection(maxCharacters: 100) == "late copy")
    #expect(pasteboard.string == "user's clipboard")
  }

  @Test("a copy that lands after the timeout still gets the user's clipboard back")
  func lateCopyRestored() async throws {
    let pasteboard = FakeCopyPasteboard()
    // The app answers nothing in time; its copy lands once the press has given up.
    let copy = SelectionCopy(
      pasteboard: pasteboard, postCopy: { true }, timeout: .milliseconds(20), lateCopyWindow: .seconds(5))
    #expect(await copy.copySelection(maxCharacters: 100) == nil)
    _ = pasteboard.answerCopy(with: "the highlighted text")()
    let deadline = ContinuousClock.now + .seconds(5)
    while pasteboard.restoreCount == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(pasteboard.string == "user's clipboard")
  }

  @Test("a Blurt paste during the copy wait isn't read as the selection or restored over")
  func ownWriteDuringCopyWait() async {
    let pasteboard = FakeCopyPasteboard()
    let copy = SelectionCopy(
      pasteboard: pasteboard,
      postCopy: {
        pasteboard.ownWrite("an earlier dictation")
        return true
      },
      timeout: .milliseconds(200))
    #expect(await copy.copySelection(maxCharacters: 100) == nil)
    #expect(pasteboard.restoreCount == 0)
    #expect(pasteboard.string == "an earlier dictation")
  }

  @Test("a paste inside the late-copy window is left alone and ends the watch")
  func lateWatchSparesOwnWrite() async throws {
    let pasteboard = FakeCopyPasteboard()
    let copy = SelectionCopy(
      pasteboard: pasteboard, postCopy: { true }, timeout: .milliseconds(20), lateCopyWindow: .milliseconds(300))
    #expect(await copy.copySelection(maxCharacters: 100) == nil)
    pasteboard.ownWrite("the dictation")
    // A copy after Blurt's write must not be restored either: the watch is over.
    try await Task.sleep(for: .milliseconds(60))
    _ = pasteboard.answerCopy(with: "the highlighted text")()
    try await Task.sleep(for: .milliseconds(400))
    #expect(pasteboard.restoreCount == 0)
    #expect(pasteboard.string == "the highlighted text")
  }

  @Test("the fallback runs only when AX was unreadable, never on a bare caret")
  func resolveRule() async {
    let pasteboard = FakeCopyPasteboard()
    let copy = copy(pasteboard, answering: "copied")
    #expect(await SelectionSpeaker.resolve(.text("from AX"), copy: copy) == "from AX")
    #expect(await SelectionSpeaker.resolve(.none, copy: copy) == nil)
    #expect(pasteboard.changeCount == 0)
    #expect(await SelectionSpeaker.resolve(.unreadable, copy: copy) == "copied")
  }

  @Test("a copy of only zero-width characters reads as nothing selected")
  func invisibleCopy() async {
    let pasteboard = FakeCopyPasteboard()
    #expect(await copy(pasteboard, answering: "\u{200B}").copySelection(maxCharacters: 100) == nil)
  }
}
