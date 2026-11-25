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
  let lock = PasteboardLock()

  var changeCount: Int { state.withLock(\.changeCount) }
  var ownWriteCount: Int { state.withLock(\.ownWriteCount) }

  var string: String? { state.withLock(\.string) }
  var restoreCount: Int { state.withLock(\.restoreCount) }

  init(readable: Bool = true) { self.readable = readable }

  func snapshot() -> PasteboardSnapshot? {
    guard readable else {
      return nil
    }
    return PasteboardSnapshot(items: [], plainText: state.withLock(\.string))
  }
  func currentString() -> String? {
    state.withLock { board in
      let current = board.string
      if current == nil, let late = board.lateWrite {
        board.lateWrite = nil
        board.string = late
        board.changeCount += 1
      }
      return current
    }
  }
  func restore(_ saved: PasteboardSnapshot, ifChangeCountIs expected: Int) {
    state.withLock { board in
      guard board.changeCount == expected else {
        return
      }
      board.restoreCount += 1
      board.string = saved.plainText
      board.changeCount += 1
    }
  }

  /// Blurt writing the clipboard itself, as a paste does.
  func ownWrite(_ text: String) {
    state.withLock { board in
      board.ownWriteCount += 1
      board.string = text
      board.changeCount += 1
    }
  }

  /// What the target app does on ⌘C.
  func answerCopy(with copied: String?) -> @Sendable () -> Bool {
    { [self] in
      if let copied {
        state.withLock { board in
          board.string = copied
          board.changeCount += 1
        }
      }
      return true
    }
  }
}
