import AppKit
import Foundation

/// A thread-safe, value-type representation of a pasteboard item containing its data
/// keyed by pasteboard types, allowing it to cross concurrency boundaries safely.
struct SendablePasteboardItem: Sendable {
  let dataMap: [NSPasteboard.PasteboardType: Data]
}

/// The two clipboard operations `KeyInjector` actually performs around a paste —
/// a plain overwrite, or an overwrite that can later restore what it displaced —
/// rather than exposing NSPasteboard's raw change-count/multi-item bookkeeping.
/// A seam so tests substitute a trivial in-memory fake that never has to
/// re-derive the pasteboard's change-count semantics to stay faithful.
protocol ClipboardAccess: Sendable {
  /// Overwrite the clipboard with a single plain-string item, discarding the
  /// previous contents. The degraded paste paths call this to leave the
  /// transcript on the clipboard for a manual paste.
  func write(_ text: String)
  /// Overwrite the clipboard with `text`, returning an action that restores the
  /// previous contents — but only if nothing else has written to the clipboard
  /// in the meantime (so a user copy during the paste-settle window survives).
  /// Call the returned action once the paste has settled.
  func writeAndPrepareRestore(_ text: String) -> @Sendable () -> Void
}

/// `ClipboardAccess` backed by the real `NSPasteboard.general`. The change-count
/// comparison that gates the deferred restore lives here, behind the seam, so a
/// fake never re-implements it.
struct SystemClipboard: ClipboardAccess {
  func write(_ text: String) { setString(text) }

  func writeAndPrepareRestore(_ text: String) -> @Sendable () -> Void {
    let saved = currentItems()
    setString(text)
    // Snapshot the change count our own write produced. If anything else writes
    // to the pasteboard before the restore fires (e.g. the user copies
    // something), the count moves and the restore leaves their newer contents
    // alone rather than clobbering them with the stale pre-paste snapshot.
    let ourChangeCount = changeCount
    return { [self] in
      guard changeCount == ourChangeCount else { return }
      restore(saved)
    }
  }

  // MARK: - NSPasteboard building blocks (also exercised directly by SystemClipboardTests)

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
