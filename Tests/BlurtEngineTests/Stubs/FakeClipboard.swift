import AppKit
import Foundation

@testable import BlurtEngine

/// In-memory `ClipboardAccess` for tests: holds pasteboard items without
/// touching the system pasteboard, and lets a test simulate another process
/// overwriting the clipboard via `externalWrite`. Shared by the KeyInjector
/// insert and delete suites.
final class FakeClipboard: ClipboardAccess, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [SendablePasteboardItem]
  private var count = 0

  init(string: String?) {
    if let string {
      let dataMap: [NSPasteboard.PasteboardType: Data] = [.string: Data(string.utf8)]
      items = [SendablePasteboardItem(dataMap: dataMap)]
    } else {
      items = []
    }
  }

  var changeCount: Int { lock.withLock { count } }

  func currentItems() -> [SendablePasteboardItem] {
    lock.withLock { items }
  }

  func setString(_ text: String) {
    let dataMap: [NSPasteboard.PasteboardType: Data] = [.string: Data(text.utf8)]
    let item = SendablePasteboardItem(dataMap: dataMap)
    lock.withLock {
      items = [item]
      count += 1
    }
  }

  func restore(_ newItems: [SendablePasteboardItem]) {
    lock.withLock {
      items = newItems
      count += 1
    }
  }

  /// Simulate another process writing the clipboard mid-paste.
  func externalWrite(_ text: String) { setString(text) }

  /// Current plain-string content, for assertions.
  var string: String? {
    lock.withLock {
      guard let first = items.first,
        let data = first.dataMap[.string]
      else { return nil }
      return String(data: data, encoding: .utf8)
    }
  }
}
