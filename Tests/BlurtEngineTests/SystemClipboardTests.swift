#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// Covers `SystemClipboard`, the real-`NSPasteboard` implementation of the
  /// `ClipboardAccess` seam (`KeyInjector` uses a fake in its own tests). These
  /// run synchronously with no settle window, so they don't race other processes'
  /// clipboard activity; `.serialized` because they touch `NSPasteboard.general`.
  @Suite("SystemClipboard", .serialized)
  struct SystemClipboardTests {

    /// Snapshot/restore the user's clipboard around a test body so the suite leaves
    /// the real pasteboard as it found it.
    ///
    /// Uses the full `snapshot()`/`restore()` primitives rather than just the string
    /// flavor: snapshotting only `.string` and then clearing unconditionally meant
    /// running these tests wiped a developer's real clipboard whenever it held an
    /// image, a file, or styled text.
    private func withClipboardRestored(_ body: () throws -> Void) rethrows {
      let clip = SystemClipboard()
      let saved = clip.snapshot()
      defer {
        if let saved { clip.restore(saved) }
      }
      try body()
    }

    @Test("setString writes the string and advances changeCount")
    func setStringWrites() {
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        let before = clip.changeCount
        clip.setString("written")

        #expect(pb.string(forType: .string) == "written")
        #expect(clip.changeCount > before)
      }
    }

    @Test("snapshot captures contents that restore brings back")
    func snapshotRestoreRoundTrips() throws {
      try withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        pb.clearContents()
        pb.setString("original", forType: .string)
        let snapshot = try #require(clip.snapshot())

        clip.setString("overwritten")
        #expect(pb.string(forType: .string) == "overwritten")

        clip.restore(snapshot)
        #expect(pb.string(forType: .string) == "original")
      }
    }

    @Test("snapshot/restore preserves every representation of multi-type, multi-item contents")
    func multiTypeSnapshotRoundTrips() throws {
      // The reason `SendablePasteboardItem` keys data by pasteboard *type*: a copy
      // of styled text carries several representations (plain string + RTF), and
      // the restore must bring all of them back — a string-only round trip would
      // silently downgrade the user's clipboard to plain text.
      try withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        let styled = NSPasteboardItem()
        styled.setString("styled", forType: .string)
        styled.setData(Data("{\\rtf1 styled}".utf8), forType: .rtf)
        let plain = NSPasteboardItem()
        plain.setString("second item", forType: .string)
        pb.clearContents()
        pb.writeObjects([styled, plain])
        let snapshot = try #require(clip.snapshot())

        clip.setString("overwritten")
        clip.restore(snapshot)

        let restored = pb.pasteboardItems ?? []
        #expect(restored.count == 2)
        #expect(restored.first?.string(forType: .string) == "styled")
        #expect(restored.first?.data(forType: .rtf) == Data("{\\rtf1 styled}".utf8))
        #expect(restored.last?.string(forType: .string) == "second item")
      }
    }

    @Test("a degraded snapshot never clears the clipboard it cannot replace")
    func degradedSnapshotDoesNotDestroy() {
      // The failure this guards: an item that exists but whose representations can't
      // be materialized (a promise the owning app declines) used to produce an
      // all-empty snapshot, and `restore` cleared first and wrote nothing — so the
      // user's clipboard came back EMPTY instead of unchanged.
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        // An item with a declared type but no retrievable data models the promise.
        let degraded = PasteboardSnapshot(
          items: [SendablePasteboardItem(dataMap: [:])], plainText: nil)

        clip.setString("transcript")
        clip.restore(degraded)

        // Left alone rather than emptied — the transcript is still recoverable.
        #expect(pb.string(forType: .string) == "transcript")
      }
    }

    @Test("a partly-readable snapshot falls back to the plain-text floor")
    func degradedSnapshotUsesTextFloor() {
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        let degraded = PasteboardSnapshot(
          items: [SendablePasteboardItem(dataMap: [:])], plainText: "original text")

        clip.setString("transcript")
        clip.restore(degraded)

        // Not byte-faithful (the richer flavors are unrecoverable), but the user's
        // text survives instead of their clipboard being emptied.
        #expect(pb.string(forType: .string) == "original text")
      }
    }

    @Test("writeAndPrepareRestore writes the text and its restore puts the saved contents back")
    func writeAndPrepareRestoreRoundTrips() {
      // The entry point `KeyInjector` actually pastes through, and the one primitive
      // in this type that no test reached: the injector suites drive `FakeClipboard`,
      // which holds a string and a counter and deliberately does *not* re-derive the
      // save-write-restore policy — the whole point of narrowing the
      // `ClipboardAccess` seam. So the policy only exists here, and only here can it
      // be checked.
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        pb.clearContents()
        pb.setString("original", forType: .string)

        let restore = clip.writeAndPrepareRestore("transcript")
        // The transcript is on the clipboard for the target app's ⌘V to read.
        #expect(pb.string(forType: .string) == "transcript")

        restore()
        #expect(pb.string(forType: .string) == "original")
      }
    }

    @Test("a clipboard changed after our paste is left alone rather than restored over")
    func restoreSkipsAfterAnExternalWrite() {
      // The change-count guard. The restore is deferred by `pasteSettleDuration`, and
      // during that window the user may copy something new — restoring then would
      // silently destroy what they just copied, which is a worse outcome than leaving
      // the transcript behind. So a pasteboard that has moved on since our write is
      // not touched.
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        pb.clearContents()
        pb.setString("original", forType: .string)
        let restore = clip.writeAndPrepareRestore("transcript")

        // Someone else copies inside the settle window.
        pb.clearContents()
        pb.setString("user copied this", forType: .string)

        restore()
        #expect(pb.string(forType: .string) == "user copied this")
      }
    }

    @Test("write overwrites the clipboard with just the text")
    func writeOverwrites() {
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        pb.clearContents()
        pb.setString("previous", forType: .string)
        // The `ClipboardAccess` half the degraded paste paths use: no restore is
        // prepared, because the transcript is meant to *stay* on the clipboard for
        // the user to paste by hand. So the previous contents must be gone.
        clip.write("transcript")

        #expect(pb.string(forType: .string) == "transcript")
      }
    }

    @Test("restore of an empty snapshot leaves the cleared pasteboard empty")
    func restoreEmptyIsNoOp() throws {
      try withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        pb.clearContents()  // an empty pasteboard has no items to snapshot
        let empty = try #require(clip.snapshot())
        clip.setString("temp")
        clip.restore(empty)

        #expect(pb.string(forType: .string) == nil)
      }
    }
  }
#endif
