import Foundation
import Synchronization

@testable import BlurtEngine

/// In-memory `ClipboardAccess` for tests: holds a single plain string without
/// touching the system pasteboard, and lets a test simulate another process
/// overwriting the clipboard via `externalWrite`. Shared by the KeyInjector
/// insert and delete suites. A `Mutex` guards the state, making the `Sendable`
/// conformance compiler-checked.
///
/// The narrowed `ClipboardAccess` seam keeps the pasteboard's change-count and
/// restore-if-unchanged policy inside `SystemClipboard`, so this fake only has
/// to hold a string and a write counter — it never re-derives that policy.
final class FakeClipboard: ClipboardAccess, Sendable {
  private struct State {
    var text: String?
    var count = 0
  }
  private let state: Mutex<State>

  init(string: String?) {
    state = Mutex(State(text: string))
  }

  func write(_ text: String) {
    state.withLock {
      $0.text = text
      $0.count += 1
    }
  }

  func writeAndPrepareRestore(_ text: String) -> @Sendable () -> Void {
    let (saved, mark) = state.withLock { s -> (String?, Int) in
      let previous = s.text
      s.text = text
      s.count += 1
      return (previous, s.count)
    }
    return { [self] in
      state.withLock { s in
        // Another writer bumped the count during the settle window — leave their
        // newer contents alone (mirrors SystemClipboard's changeCount guard).
        guard s.count == mark else { return }
        s.text = saved
        s.count += 1
      }
    }
  }

  /// Simulate another process writing the clipboard mid-paste.
  func externalWrite(_ text: String) { write(text) }

  /// Current plain-string content, for assertions.
  var string: String? {
    state.withLock { $0.text }
  }
}
