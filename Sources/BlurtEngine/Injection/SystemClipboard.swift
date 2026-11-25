#if os(macOS)
  import AppKit
  import Foundation
  import Synchronization

  /// `ClipboardAccess` backed by the real `NSPasteboard.general`. The change-count
  /// comparison that gates the deferred restore lives here, behind the seam, so a
  /// fake never re-implements it.
  struct SystemClipboard: ClipboardAccess {
    /// Arranges for a concealed leave-behind's expiry to run later.
    typealias ExpiryScheduler = @Sendable (_ expire: @escaping @Sendable () -> Void) -> Void

    /// How long a concealed leave-behind stays for the paste by hand before it
    /// is cleared (`TargetSecurity.concealedClipboardLifetime`).
    static let concealedLifetime = TargetSecurity.concealedClipboardLifetime

    /// Counts the writes Blurt itself makes to the pasteboard, bumped *before*
    /// each one, so a reader that sees the pasteboard's change count move can
    /// then tell whether Blurt made the change (`SelectionCopy`'s late-copy
    /// watcher must never restore over a paste's transcript).
    private static let ownWrites = Atomic<Int>(0)

    /// nspasteboard.org's marker for contents that exist only for a moment.
    /// Clipboard managers (Raycast, Maccy, Alfred) skip an item carrying it, so
    /// the paste's transcript and the restore that follows it don't land in the
    /// user's clipboard history as copies they never made. The data is empty:
    /// the type's presence is the whole signal.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// nspasteboard.org's marker for a secret — what a password manager puts on
    /// its copy. Clipboard managers skip it (and may hide it) even where they
    /// keep transient items. Empty data, like `transientType`.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Runs a concealed leave-behind's expiry once `concealedLifetime` has
    /// passed. Injectable so tests can see an expiry was scheduled, and run it,
    /// without waiting the lifetime out.
    private let scheduleExpiry: ExpiryScheduler

    var lock: PasteboardLock { .system }

    // MARK: - NSPasteboard building blocks (also exercised directly by SystemClipboardTests)

    var changeCount: Int { NSPasteboard.general.changeCount }

    var ownWriteCount: Int { Self.ownWrites.load(ordering: .sequentiallyConsistent) }

    init(scheduleExpiry: @escaping ExpiryScheduler = { Self.afterLifetime($0) }) {
      self.scheduleExpiry = scheduleExpiry
    }

    /// The production `ExpiryScheduler`: `expire` after `concealedLifetime`.
    static func afterLifetime(_ expire: @escaping @Sendable () -> Void) {
      Task.detached {
        try? await Task.sleep(for: Self.concealedLifetime)
        expire()
      }
    }

    // Not transient: these words are meant to stay for a paste by hand, so a
    // clipboard manager keeping them is a feature here — unless they were
    // dictated into a password field (#348). Those are marked concealed and
    // transient, so a manager skips them, and cleared after
    // `concealedLifetime`, so the secret doesn't sit on the pasteboard for
    // whatever reads it next.
    func write(_ text: String, concealed: Bool) {
      setString(text, transient: concealed, concealed: concealed)
      guard concealed else {
        return
      }
      expireOurWrite()
    }

    func writeAndPrepareRestore(_ text: String, concealed: Bool) -> @Sendable () -> Void {
      writeAndPrepareRestore(text, concealed: concealed, over: snapshot())
    }

    /// `writeAndPrepareRestore` over a snapshot already taken: internal so
    /// tests can hand it the unreadable pasteboard (`nil`) the real one rarely
    /// produces on demand.
    func writeAndPrepareRestore(
      _ text: String, concealed: Bool, over saved: PasteboardSnapshot?
    ) -> @Sendable () -> Void {
      setString(text, transient: true, concealed: concealed)
      // Snapshot the change count our own write produced. If anything else writes
      // to the pasteboard before the restore fires (e.g. the user copies
      // something), the count moves and the restore leaves their newer contents
      // alone rather than clobbering them with the stale pre-paste snapshot.
      let ourChangeCount = changeCount
      // With no snapshot the restore below leaves these words in place, so a
      // secret's are given the same expiry as a concealed leave-behind's:
      // nothing else would ever take a password off the clipboard.
      if concealed, saved == nil {
        expireOurWrite()
      }
      return { [self] in
        // A nil snapshot means the pasteboard could not be read at all. There is
        // nothing to put back, so leave the transcript on the clipboard (the same
        // degraded-but-recoverable outcome as the `.noTarget` path) rather than
        // clearing the user's clipboard to nothing.
        guard let saved else {
          return
        }
        restore(saved, ifChangeCountIs: ourChangeCount)
      }
    }

    /// Puts `saved` back, unless something wrote to the pasteboard since
    /// `expected` was read: a newer copy by the user survives. Shared by the
    /// paste path and the read-aloud copy fallback (`SelectionCopy`).
    ///
    /// A concealed snapshot gets a fresh expiry once it is back. Whatever was
    /// going to clear it — `write`'s own timer for a password field's
    /// leave-behind, or a password manager's for its copy — keyed on the change
    /// count before this paste, so it now finds a different one and skips the
    /// clear, and the secret would stay on the pasteboard for good.
    func restore(_ saved: PasteboardSnapshot, ifChangeCountIs expected: Int) {
      guard changeCount == expected else {
        return
      }
      restore(saved)
      if saved.isConcealed { expireOurWrite() }
    }

    private func noteOwnWrite() { Self.ownWrites.add(1, ordering: .sequentiallyConsistent) }

    /// Clears the write just made once `concealedLifetime` has passed, unless
    /// something has written to the pasteboard since (`clear(ifChangeCountIs:)`).
    private func expireOurWrite() {
      let ours = changeCount
      scheduleExpiry { [self] in
        clear(ifChangeCountIs: ours)
      }
    }

    /// Snapshots the pasteboard, or `nil` when it can't be read at all
    /// (`pasteboardItems` is documented to return nil on error). Callers must treat
    /// nil as "don't restore" — never as an empty clipboard.
    func snapshot() -> PasteboardSnapshot? {
      let pasteboard = NSPasteboard.general
      guard let items = pasteboard.pasteboardItems else {
        return nil
      }
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

    /// `concealed` also keeps the words to this Mac: `currentHostOnly` takes
    /// them off Universal Clipboard, so a secret isn't handed to the user's
    /// other devices.
    func setString(_ text: String, transient: Bool = false, concealed: Bool = false) {
      noteOwnWrite()
      let pasteboard = NSPasteboard.general
      if concealed {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
      } else {
        pasteboard.clearContents()
      }
      pasteboard.setString(text, forType: .string)
      if transient { pasteboard.setData(Data(), forType: Self.transientType) }
      if concealed { pasteboard.setData(Data(), forType: Self.concealedType) }
    }

    /// Empties the pasteboard, unless something wrote to it since `expected`
    /// was read: a concealed leave-behind expiring must not take a newer copy
    /// with it.
    func clear(ifChangeCountIs expected: Int) {
      guard changeCount == expected else {
        return
      }
      noteOwnWrite()
      NSPasteboard.general.clearContents()
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
      let rebuilt = saved.items.compactMap { item -> NSPasteboardItem? in
        guard !item.dataMap.isEmpty else {
          return nil
        }
        let pasteboardItem = NSPasteboardItem()
        for (type, data) in item.dataMap {
          pasteboardItem.setData(data, forType: type)
        }
        // Putting the user's own contents back is not a new copy: without the
        // marker a clipboard manager records it again, on every dictation.
        pasteboardItem.setData(Data(), forType: Self.transientType)
        return pasteboardItem
      }

      // The text floor rides the rebuilt items too, not only the fallback below.
      // An item can be non-empty without its text: a marker type such as
      // nspasteboard.org's `ConcealedType` (a password manager's copy) is
      // *meant* to be empty `Data`, so it is kept, while the string beside it
      // was a promise that declined. That batch writes fine, and returning on
      // it put back the marker and dropped the password the snapshot still held.
      if let plainText = saved.plainText, let first = rebuilt.first,
        !saved.items.contains(where: { $0.dataMap[.string] != nil })
      {
        first.setString(plainText, forType: .string)
      }

      if !rebuilt.isEmpty {
        // A restored secret stays on this Mac, as `setString` keeps a new one.
        if saved.isConcealed {
          pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
          pasteboard.clearContents()
        }
        // `writeObjects` can refuse the batch; fall through to the text floor
        // rather than leaving the pasteboard empty.
        if pasteboard.writeObjects(rebuilt) {
          return
        }
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
        setString(plainText, transient: true, concealed: saved.isConcealed)
      }
    }
  }

  /// The read-aloud copy fallback's view of the pasteboard (see `SelectionCopy`).
  extension SystemClipboard: CopyPasteboard {
    func currentString() -> String? { NSPasteboard.general.string(forType: .string) }
  }
#endif
