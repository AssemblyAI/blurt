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
  }
#endif
