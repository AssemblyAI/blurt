import AppKit
import Foundation

/// A thread-safe, value-type representation of a pasteboard item containing its data
/// keyed by pasteboard types, allowing it to cross concurrency boundaries safely.
struct SendablePasteboardItem: Sendable {
  let dataMap: [NSPasteboard.PasteboardType: Data]
}

/// A best-effort snapshot of the whole pasteboard, taken before a paste so the
/// user's contents can be put back afterwards.
///
/// The distinction that matters: this type is only ever produced when the
/// pasteboard was *readable*. `SystemClipboard.snapshot()` returns `nil` when the
/// read itself failed, so a failure can never be mistaken for "the clipboard was
/// empty" — conflating those two is what made the restore clear the user's
/// clipboard instead of restoring it.
///
/// Known, inherent limitation: pasteboard data can be *promised* (provided lazily
/// by the owning app on demand). A promise cannot be copied, only materialized, and
/// an app may decline. Types that decline are absent from `dataMap`, so a restore
/// of promise-backed contents is a best-effort downgrade, not a byte-faithful
/// round trip — `plainText` exists to keep at least the text when that happens.
struct PasteboardSnapshot: Sendable {
  /// One entry per item the pasteboard held, in order. An entry with an empty
  /// `dataMap` means the item existed but none of its representations could be
  /// materialized — distinct from the pasteboard having held no items at all,
  /// which is `items.isEmpty`.
  let items: [SendablePasteboardItem]
  /// The pasteboard's plain-string flavor, kept separately as a restore floor for
  /// when no item's representations could be materialized.
  let plainText: String?
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
    let saved = snapshot()
    setString(text)
    // Snapshot the change count our own write produced. If anything else writes
    // to the pasteboard before the restore fires (e.g. the user copies
    // something), the count moves and the restore leaves their newer contents
    // alone rather than clobbering them with the stale pre-paste snapshot.
    let ourChangeCount = changeCount
    return { [self] in
      guard changeCount == ourChangeCount else { return }
      // A nil snapshot means the pasteboard could not be read at all. There is
      // nothing to put back, so leave the transcript on the clipboard (the same
      // degraded-but-recoverable outcome as the `.noTarget` path) rather than
      // clearing the user's clipboard to nothing.
      guard let saved else { return }
      restore(saved)
    }
  }

  // MARK: - NSPasteboard building blocks (also exercised directly by SystemClipboardTests)

  var changeCount: Int { NSPasteboard.general.changeCount }

  /// Snapshots the pasteboard, or `nil` when it can't be read at all
  /// (`pasteboardItems` is documented to return nil on error). Callers must treat
  /// nil as "don't restore" — never as an empty clipboard.
  func snapshot() -> PasteboardSnapshot? {
    let pasteboard = NSPasteboard.general
    guard let items = pasteboard.pasteboardItems else { return nil }
    let captured = items.map { item in
      var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types {
        // A nil read is a promised representation the owning app declined to
        // materialize; record what we did get and let `plainText` be the floor.
        if let data = item.data(forType: type) {
          dataMap[type] = data
        }
      }
      return SendablePasteboardItem(dataMap: dataMap)
    }
    return PasteboardSnapshot(items: captured, plainText: pasteboard.string(forType: .string))
  }

  func setString(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  func restore(_ saved: PasteboardSnapshot) {
    let pasteboard = NSPasteboard.general

    // The pasteboard genuinely held nothing, so restoring it means emptying it.
    // Safe to clear because the snapshot succeeded — a *failed* read is nil and
    // never reaches here.
    guard !saved.items.isEmpty else {
      pasteboard.clearContents()
      return
    }

    // Build the items BEFORE clearing. Clearing first and then discovering there
    // is nothing to write is how the user's clipboard got destroyed whenever a
    // snapshot came back degraded.
    let rebuilt = saved.items.compactMap { item -> NSPasteboardItem? in
      guard !item.dataMap.isEmpty else { return nil }
      let pasteboardItem = NSPasteboardItem()
      for (type, data) in item.dataMap {
        pasteboardItem.setData(data, forType: type)
      }
      return pasteboardItem
    }

    if !rebuilt.isEmpty {
      pasteboard.clearContents()
      // `writeObjects` can refuse the batch; fall through to the text floor
      // rather than leaving the pasteboard empty.
      if pasteboard.writeObjects(rebuilt) { return }
    }

    // Either nothing was materializable, or the write above was refused. Put the
    // text back if we have it.
    //
    // Precise about the one case this does NOT recover: if items DID materialize,
    // `writeObjects` refused them, and there was no plain-string flavor, the
    // pasteboard has already been cleared and stays empty. That is not gated on
    // `plainText` being non-nil on purpose — skipping the item write whenever
    // there's no text flavor would refuse to restore an image-only or
    // file-only clipboard, which is a far more common clipboard than a refused
    // batch write. `writeObjects` failing on a freshly-cleared pasteboard holding
    // valid `NSPasteboardItem`s is a programming error, not a runtime condition,
    // and NSPasteboard offers no way to test a write before clearing.
    if let plainText = saved.plainText {
      pasteboard.clearContents()
      pasteboard.setString(plainText, forType: .string)
    }
  }
}
