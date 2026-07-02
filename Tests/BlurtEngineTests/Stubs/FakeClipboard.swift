import AppKit
import Foundation
import Synchronization

@testable import BlurtEngine

/// In-memory `ClipboardAccess` for tests: holds pasteboard items without
/// touching the system pasteboard, and lets a test simulate another process
/// overwriting the clipboard via `externalWrite`. Shared by the KeyInjector
/// insert and delete suites. A `Mutex` guards the state, making the `Sendable`
/// conformance compiler-checked.
final class FakeClipboard: ClipboardAccess, Sendable {
  private struct State {
    var items: [SendablePasteboardItem]
    var count = 0
  }
  private let state: Mutex<State>

  init(string: String?) {
    if let string {
      let dataMap: [NSPasteboard.PasteboardType: Data] = [.string: Data(string.utf8)]
      state = Mutex(State(items: [SendablePasteboardItem(dataMap: dataMap)]))
    } else {
      state = Mutex(State(items: []))
    }
  }

  var changeCount: Int { state.withLock { $0.count } }

  func currentItems() -> [SendablePasteboardItem] {
    state.withLock { $0.items }
  }

  func setString(_ text: String) {
    let dataMap: [NSPasteboard.PasteboardType: Data] = [.string: Data(text.utf8)]
    let item = SendablePasteboardItem(dataMap: dataMap)
    state.withLock {
      $0.items = [item]
      $0.count += 1
    }
  }

  func restore(_ newItems: [SendablePasteboardItem]) {
    state.withLock {
      $0.items = newItems
      $0.count += 1
    }
  }

  /// Simulate another process writing the clipboard mid-paste.
  func externalWrite(_ text: String) { setString(text) }

  /// Current plain-string content, for assertions.
  var string: String? {
    state.withLock {
      guard let first = $0.items.first,
        let data = first.dataMap[.string]
      else { return nil }
      return String(data: data, encoding: .utf8)
    }
  }
}
