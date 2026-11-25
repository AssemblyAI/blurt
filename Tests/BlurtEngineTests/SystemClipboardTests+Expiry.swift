#if os(macOS)
  import AppKit
  import Synchronization
  import Testing

  @testable import BlurtEngine

  /// Records the expiries a `SystemClipboard` schedules instead of sleeping
  /// them out, so a test can count them and run them at once.
  private final class ExpiryRecorder: Sendable {
    private let pending = Mutex<[@Sendable () -> Void]>([])

    var count: Int { pending.withLock { $0.count } }

    var isEmpty: Bool { pending.withLock { $0.isEmpty } }

    func schedule(_ expire: @escaping @Sendable () -> Void) {
      pending.withLock { $0.append(expire) }
    }

    func runAll() {
      let all = pending.withLock { $0 }
      for expire in all { expire() }
    }
  }

  /// Which writes `SystemClipboard` gives the concealed expiry (#348): every
  /// concealed leave-behind, and a concealed paste whose restore has nothing
  /// to put back — the one case where nothing else would ever take the
  /// password off the clipboard. An extension of `SystemClipboardTests`, not
  /// a suite of its own, so it stays serialized with the rest of the
  /// real-pasteboard tests.
  extension SystemClipboardTests {
    @Test("a concealed leave-behind schedules its expiry; a plain one doesn't")
    func concealedWriteSchedulesExpiry() {
      withClipboardRestored {
        let recorder = ExpiryRecorder()
        let clip = SystemClipboard { recorder.schedule($0) }

        clip.write("transcript", concealed: false)
        #expect(recorder.isEmpty)

        clip.write("hunter2", concealed: true)
        #expect(recorder.count == 1)
        recorder.runAll()
        #expect(NSPasteboard.general.string(forType: .string) == nil)
      }
    }

    /// Finding: with an unreadable pasteboard the restore leaves the paste's
    /// words in place, so a password pasted then sat on the clipboard for good.
    @Test("a concealed paste over an unreadable clipboard expires the words the restore leaves")
    func concealedPasteWithNoSnapshotExpires() {
      withClipboardRestored {
        let pb = NSPasteboard.general
        let recorder = ExpiryRecorder()
        let clip = SystemClipboard { recorder.schedule($0) }

        let restore = clip.writeAndPrepareRestore("hunter2", concealed: true, over: nil)
        #expect(recorder.count == 1)
        restore()
        // Nothing to put back, so the words stay for now…
        #expect(pb.string(forType: .string) == "hunter2")
        // …until the expiry takes them.
        recorder.runAll()
        #expect(pb.string(forType: .string) == nil)
      }
    }

    @Test("a paste the restore can undo schedules no expiry, concealed or not")
    func restorablePasteSchedulesNothing() {
      withClipboardRestored {
        let pb = NSPasteboard.general
        let recorder = ExpiryRecorder()
        let clip = SystemClipboard { recorder.schedule($0) }
        pb.clearContents()
        pb.setString("original", forType: .string)

        let restore = clip.writeAndPrepareRestore("hunter2", concealed: true)
        restore()
        #expect(pb.string(forType: .string) == "original")

        // An ordinary paste over an unreadable clipboard keeps its words, as
        // the `.noTarget` path does: only a secret is worth taking away.
        _ = clip.writeAndPrepareRestore("transcript", concealed: false, over: nil)
        #expect(recorder.isEmpty)
      }
    }

    /// A password left on the clipboard, snapshotted by the next paste and put
    /// back: its first expiry keyed on the count before that paste and skips,
    /// so the restore must give it a fresh one.
    @Test("a secret the restore puts back gets an expiry of its own")
    func restoredSecretExpires() {
      withClipboardRestored {
        let pb = NSPasteboard.general
        let recorder = ExpiryRecorder()
        let clip = SystemClipboard { recorder.schedule($0) }
        // The leave-behind, its own expiry kept aside: it would skip anyway.
        let firstExpiry = ExpiryRecorder()
        SystemClipboard { firstExpiry.schedule($0) }.write("hunter2", concealed: true)

        let restore = clip.writeAndPrepareRestore("transcript", concealed: false)
        restore()
        #expect(pb.string(forType: .string) == "hunter2")
        #expect(recorder.count == 1)
        recorder.runAll()

        #expect(pb.string(forType: .string) == nil)
      }
    }

    @Test("an expiry never clears a copy made after the concealed write")
    func noSnapshotExpirySparesNewerCopy() {
      withClipboardRestored {
        let pb = NSPasteboard.general
        let recorder = ExpiryRecorder()
        let clip = SystemClipboard { recorder.schedule($0) }

        _ = clip.writeAndPrepareRestore("hunter2", concealed: true, over: nil)
        pb.clearContents()
        pb.setString("user copied this", forType: .string)
        recorder.runAll()

        #expect(pb.string(forType: .string) == "user copied this")
      }
    }

    /// The invariant `SystemClipboard.put` holds by construction: every path
    /// that puts a secret down is counted as Blurt's own write, marked, and
    /// given exactly one expiry. Each security fix before it found a path the
    /// rule had missed. (`currentHostOnly` has no public read-back, so that
    /// half is pinned only by `put` applying it with the markers.) The one
    /// concealed write without an expiry is the paste whose own restore takes
    /// it off: `restorablePasteSchedulesNothing`.
    @Test("every concealed write path is counted, marked and given one expiry")
    func everyConcealedWriteExpires() {
      withClipboardRestored {
        let pb = NSPasteboard.general
        let marker = [SystemClipboard.concealedType: Data()]
        var secret = marker
        secret[.string] = Data("hunter2".utf8)
        let whole = PasteboardSnapshot(items: [SendablePasteboardItem(dataMap: secret)], plainText: "hunter2")
        // The string declined to materialize: only the text floor carries it.
        let floored = PasteboardSnapshot(items: [SendablePasteboardItem(dataMap: marker)], plainText: "hunter2")
        let paths: [(name: String, run: (SystemClipboard) -> Void)] = [
          ("leave-behind", { $0.write("hunter2", concealed: true) }),
          ("unreadable-clipboard paste", { _ = $0.writeAndPrepareRestore("hunter2", concealed: true, over: nil) }),
          ("restore", { $0.restore(whole) }),
          ("restore if unchanged", { $0.restore(whole, ifChangeCountIs: $0.changeCount) }),
          ("restore by the text floor", { $0.restore(floored) }),
        ]
        for path in paths {
          let recorder = ExpiryRecorder()
          let clip = SystemClipboard { recorder.schedule($0) }
          clip.write("before", concealed: false)
          let ownWrites = clip.ownWriteCount

          path.run(clip)

          #expect(clip.ownWriteCount > ownWrites, "\(path.name)")
          #expect(pb.string(forType: .string) == "hunter2", "\(path.name)")
          #expect(pb.types?.contains(SystemClipboard.concealedType) == true, "\(path.name)")
          #expect(pb.types?.contains(SystemClipboard.transientType) == true, "\(path.name)")
          #expect(recorder.count == 1, "\(path.name)")
          recorder.runAll()
          #expect(pb.string(forType: .string) == nil, "\(path.name)")
        }
      }
    }
  }
#endif
