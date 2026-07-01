import AppKit
import Foundation

/// A thread-safe, value-type representation of a pasteboard item containing its data
/// keyed by pasteboard types, allowing it to cross concurrency boundaries safely.
struct SendablePasteboardItem: Sendable {
  let dataMap: [NSPasteboard.PasteboardType: Data]
}

/// The pasteboard operations `KeyInjector` needs to save, overwrite, and restore
/// the clipboard around a paste. Seam so tests can substitute an in-memory fake.
protocol ClipboardAccess: Sendable {
  /// Monotonic counter that advances on every write; used to detect a write by
  /// another writer during the paste settle window.
  var changeCount: Int { get }
  /// A detached copy of the current contents, suitable for later `restore`.
  func currentItems() -> [SendablePasteboardItem]
  /// Replace the contents with a single plain-string item.
  func setString(_ text: String)
  /// Replace the contents with previously snapshotted items (no-op if empty).
  func restore(_ items: [SendablePasteboardItem])
}

/// `ClipboardAccess` backed by the real `NSPasteboard.general`.
struct SystemClipboard: ClipboardAccess {
  var changeCount: Int { NSPasteboard.general.changeCount }

  func currentItems() -> [SendablePasteboardItem] {
    guard let items = NSPasteboard.general.pasteboardItems else { return [] }
    return items.map { item in
      var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        if let data = item.data(forType: type) {
          dataMap[type] = data
        }
      }
      return SendablePasteboardItem(dataMap: dataMap)
    }
  }

  func setString(_ text: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
  }

  func restore(_ items: [SendablePasteboardItem]) {
    let pb = NSPasteboard.general
    pb.clearContents()
    guard !items.isEmpty else { return }
    let pbItems = items.map { item in
      let pbItem = NSPasteboardItem()
      for (type, data) in item.dataMap {
        pbItem.setData(data, forType: type)
      }
      return pbItem
    }
    pb.writeObjects(pbItems)
  }
}
