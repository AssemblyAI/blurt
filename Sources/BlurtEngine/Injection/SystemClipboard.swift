#if os(macOS)
  import AppKit
  import Foundation
  import Synchronization

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
    /// The pasteboard's plain-string flavor, kept separately as a restore floor:
    /// `SystemClipboard.restorableItems` folds it into the first item whenever no
    /// item kept a non-empty string of its own — even if other representations
    /// (RTF, nspasteboard.org markers) did materialize — so a promised string
    /// the owning app declined still comes back.
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
    /// transcript on the clipboard for a manual paste. `concealed` is set when
    /// the words were dictated into a password field: they are still left for
    /// the hand-paste, but marked so a clipboard manager never records them.
    func write(_ text: String, concealed: Bool)
    /// Overwrite the clipboard with `text`, returning an action that restores the
    /// previous contents — but only if nothing else has written to the clipboard
    /// in the meantime (so a user copy during the paste-settle window survives).
    /// Call the returned action once the paste has settled. `concealed` as for
    /// `write`.
    func writeAndPrepareRestore(_ text: String, concealed: Bool) -> @Sendable () -> Void
  }

  /// `ClipboardAccess` backed by the real `NSPasteboard.general`. The change-count
  /// comparison that gates the deferred restore lives here, behind the seam, so a
  /// fake never re-implements it.
  struct SystemClipboard: ClipboardAccess {
    /// How long a concealed write may sit on the clipboard before it is cleared:
    /// 1Password's default ("clear copied information after 90 seconds"), so a
    /// dictated password lasts exactly as long as one copied from a password
    /// manager. Only Blurt's own write is cleared — see `setString`.
    var concealedLifetime: Duration = .seconds(90)

    // Not transient: these words are meant to stay for a paste by hand, so a
    // clipboard manager keeping them is a feature here — unless they went into a
    // password field (issue #348). Then they are handled the way 1Password
    // handles a copied password: concealed *and* transient, so no manager
    // archives it (both markers, because some managers record a Concealed-only
    // item and merely hide it); this Mac only, so Universal Clipboard doesn't
    // carry it to the user's other devices; and cleared after
    // `concealedLifetime`. The hand-paste still works in the meantime.
    func write(_ text: String, concealed: Bool) {
      setString(text, transient: concealed, concealed: concealed)
    }

    func writeAndPrepareRestore(_ text: String, concealed: Bool) -> @Sendable () -> Void {
      let saved = snapshot()
      setString(text, transient: true, concealed: concealed)
      // Snapshot the change count our own write produced. If anything else writes
      // to the pasteboard before the restore fires (e.g. the user copies
      // something), the count moves and the restore leaves their newer contents
      // alone rather than clobbering them with the stale pre-paste snapshot.
      let ourChangeCount = changeCount
      return { [self] in
        // A nil snapshot means the pasteboard could not be read at all. There is
        // nothing to put back, so leave the transcript on the clipboard (the same
        // degraded-but-recoverable outcome as the `.noTarget` path) rather than
        // clearing the user's clipboard to nothing.
        guard let saved else { return }
        restore(saved, ifChangeCountIs: ourChangeCount)
      }
    }

    /// Puts `saved` back, unless something wrote to the pasteboard since
    /// `expected` was read: a newer copy by the user survives. Shared by the
    /// paste path and the read-aloud copy fallback (`SelectionCopy`).
    func restore(_ saved: PasteboardSnapshot, ifChangeCountIs expected: Int) {
      guard changeCount == expected else { return }
      restore(saved)
    }

    // MARK: - NSPasteboard building blocks (also exercised directly by SystemClipboardTests)

    var changeCount: Int { NSPasteboard.general.changeCount }

    /// Counts the writes Blurt itself makes to the pasteboard, bumped *before*
    /// each one, so a reader that sees the pasteboard's change count move can
    /// then tell whether Blurt made the change (`SelectionCopy`'s late-copy
    /// watcher must never restore over a paste's transcript).
    private static let ownWrites = Atomic<Int>(0)

    var ownWriteCount: Int { Self.ownWrites.load(ordering: .sequentiallyConsistent) }

    private func noteOwnWrite() { Self.ownWrites.add(1, ordering: .sequentiallyConsistent) }

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

    /// nspasteboard.org's marker for contents that exist only for a moment.
    /// Clipboard managers (Raycast, Maccy, Alfred) skip an item carrying it, so
    /// the paste's transcript and the restore that follows it don't land in the
    /// user's clipboard history as copies they never made. The data is empty:
    /// the type's presence is the whole signal.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// nspasteboard.org's marker for sensitive contents — what a password
    /// manager sets on a copied password. Set on a transcript dictated into a
    /// secure field, the same secret `FocusCapture` refuses to read and the
    /// session refuses to remember. Empty data, like `transientType`.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    func setString(_ text: String, transient: Bool = false, concealed: Bool = false) {
      noteOwnWrite()
      let pasteboard = NSPasteboard.general
      // Both clear the old contents; `.currentHostOnly` also keeps this write off
      // Universal Clipboard, which ignores the nspasteboard.org markers.
      if concealed {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
      } else {
        pasteboard.clearContents()
      }
      pasteboard.setString(text, forType: .string)
      if transient { pasteboard.setData(Data(), forType: Self.transientType) }
      guard concealed else { return }
      pasteboard.setData(Data(), forType: Self.concealedType)
      clearAfterLifetime(ifChangeCountIs: pasteboard.changeCount)
    }

    /// Clears the concealed write once `concealedLifetime` has passed — unless
    /// anything wrote to the pasteboard since, the same guard the paste's restore
    /// uses: a newer copy by the user survives, and so does the restore itself
    /// (which is why the paste path's 400 ms restore leaves this a no-op). A
    /// restore that puts a concealed clipboard back schedules its own clear.
    private func clearAfterLifetime(ifChangeCountIs expected: Int) {
      let lifetime = concealedLifetime
      Task { [self] in
        try? await Task.sleep(for: lifetime)
        guard changeCount == expected else { return }
        noteOwnWrite()
        NSPasteboard.general.clearContents()
      }
    }

    /// The data maps `restore` writes back, one per item worth restoring.
    ///
    /// An item counts only if it carries *payload* — some non-empty data. The
    /// nspasteboard.org markers are empty `Data()` by design, so a password
    /// manager's copy whose string was promised (and declined) snapshots as a
    /// marker-only item: writing that "succeeds" and puts back nothing but the
    /// markers, the user's secret gone (issue #347).
    ///
    /// The `plainText` floor is folded into the first item whenever no item
    /// kept a string of its own, rather than written separately: the restored
    /// text then keeps that item's markers, so a concealed password comes back
    /// concealed instead of as an ordinary string a clipboard manager archives.
    static func restorableItems(
      _ saved: PasteboardSnapshot
    ) -> [[NSPasteboard.PasteboardType: Data]] {
      var maps = saved.items.map(\.dataMap)
      let keptString = maps.contains { !($0[.string]?.isEmpty ?? true) }
      if let plainText = saved.plainText, !keptString, !maps.isEmpty {
        maps[0][.string] = Data(plainText.utf8)
      }
      return maps.filter { map in map.values.contains { !$0.isEmpty } }
    }

    func restore(_ saved: PasteboardSnapshot) {
      noteOwnWrite()
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
      let rebuilt = Self.restorableItems(saved).map { dataMap in
        let pasteboardItem = NSPasteboardItem()
        for (type, data) in dataMap {
          pasteboardItem.setData(data, forType: type)
        }
        // Putting the user's own contents back is not a new copy: without the
        // marker a clipboard manager records it again, on every dictation.
        pasteboardItem.setData(Data(), forType: Self.transientType)
        return pasteboardItem
      }

      // A concealed clipboard (a password manager's copy, or a password Blurt
      // left behind) goes back the way `setString` writes one: this Mac only, so
      // Universal Clipboard — which ignores the nspasteboard.org markers —
      // doesn't carry the secret to other devices, and cleared after
      // `concealedLifetime`. The restore is itself a write, so it voids whatever
      // clear was pending on the original (ours, or the manager's own timer);
      // without a fresh one the secret would sit on the clipboard indefinitely.
      let concealed = saved.items.contains { $0.dataMap[Self.concealedType] != nil }

      if !rebuilt.isEmpty {
        if concealed {
          pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
          pasteboard.clearContents()
        }
        // `writeObjects` can refuse the batch; fall through to the text floor
        // rather than leaving the pasteboard empty.
        if pasteboard.writeObjects(rebuilt) {
          if concealed { clearAfterLifetime(ifChangeCountIs: pasteboard.changeCount) }
          return
        }
      }

      // The write above was refused (a text floor would otherwise have been folded
      // into `rebuilt`, so an unmaterializable snapshot with no text lands here
      // and, `plainText` being nil, is left alone). Put the text back if we have it.
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
        setString(plainText, transient: true, concealed: concealed)
      }
    }
  }

  /// The read-aloud copy fallback's view of the pasteboard (see `SelectionCopy`).
  extension SystemClipboard: CopyPasteboard {
    func currentString() -> String? { NSPasteboard.general.string(forType: .string) }
  }
#endif
