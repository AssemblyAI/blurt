#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import BlurtEngine

  /// `SystemClipboard`'s handling of concealed (password) contents: Blurt's own
  /// concealed writes and their expiry, and putting a password manager's copy
  /// back after a paste (issues #347, #348). An extension rather than a suite of
  /// its own so these stay in `SystemClipboardTests`' `.serialized` run — two
  /// suites would race each other on `NSPasteboard.general`.
  extension SystemClipboardTests {
    @Test("a marker-only snapshot still restores the text floor, still concealed")
    func markerOnlySnapshotUsesTextFloor() {
      // Issue #347: a password manager's copy whose string was promised snapshots
      // as nothing but the empty ConcealedType marker. That item alone made
      // `writeObjects` succeed with no string, and the plain-text floor was
      // skipped — the user's password gone after a dictation.
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        let markerOnly = PasteboardSnapshot(
          items: [SendablePasteboardItem(dataMap: [SystemClipboard.concealedType: Data()])],
          plainText: "hunter2")

        clip.setString("transcript")
        clip.restore(markerOnly)

        #expect(pb.string(forType: .string) == "hunter2")
        // Comes back marked as it was copied, so no clipboard manager archives it.
        #expect(pb.types?.contains(SystemClipboard.concealedType) == true)
        #expect(pb.types?.contains(SystemClipboard.transientType) == true)
      }
    }

    @Test("a marker-only snapshot with no text floor leaves the clipboard alone")
    func markerOnlySnapshotWithoutTextDoesNotDestroy() {
      // Markers alone are not contents: writing them back would replace the
      // transcript with an empty, unpasteable clipboard.
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        let markerOnly = PasteboardSnapshot(
          items: [SendablePasteboardItem(dataMap: [SystemClipboard.concealedType: Data()])],
          plainText: nil)

        clip.setString("transcript")
        clip.restore(markerOnly)

        #expect(pb.string(forType: .string) == "transcript")
      }
    }

    @Test("a snapshot whose items lost their string gets the text floor folded back in")
    func payloadWithoutStringGetsTextFloor() {
      // The string flavor was promised and declined, but another flavor
      // materialized: the item restores *and* keeps the user's text.
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        let partial = PasteboardSnapshot(
          items: [SendablePasteboardItem(dataMap: [.rtf: Data("{\\rtf1 styled}".utf8)])],
          plainText: "styled")

        clip.setString("transcript")
        clip.restore(partial)

        #expect(pb.string(forType: .string) == "styled")
        #expect(pb.data(forType: .rtf) == Data("{\\rtf1 styled}".utf8))
      }
    }

    @Test("a real concealed copy round-trips through writeAndPrepareRestore")
    func concealedCopyRoundTrips() {
      // The issue's reproduction end to end: string + ConcealedType, then a paste.
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        pb.clearContents()
        pb.setString("hunter2", forType: .string)
        pb.setData(Data(), forType: SystemClipboard.concealedType)

        let restore = clip.writeAndPrepareRestore("transcript", concealed: false)
        #expect(pb.string(forType: .string) == "transcript")
        restore()

        #expect(pb.string(forType: .string) == "hunter2")
        #expect(pb.types?.contains(SystemClipboard.concealedType) == true)
      }
    }

    @Test("a concealed write is marked so clipboard managers skip it")
    func concealedWriteIsMarked() {
      // Issue #348: a password dictation's quiet "copied" leave-behind. Still on
      // the clipboard for the hand-paste, but Concealed and Transient both, since
      // some managers record a Concealed-only item and merely hide it.
      withClipboardRestored {
        let pb = NSPasteboard.general
        let clip = SystemClipboard()

        clip.write("hunter2", concealed: true)

        #expect(pb.string(forType: .string) == "hunter2")
        #expect(pb.types?.contains(SystemClipboard.concealedType) == true)
        #expect(pb.types?.contains(SystemClipboard.transientType) == true)
      }
    }

    @Test("a concealed write clears itself once its lifetime passes")
    func concealedWriteExpires() async throws {
      // 1Password's behavior for a copied password: gone after a short while
      // (90 s in production; shortened here).
      let clip = SystemClipboard(concealedLifetime: .milliseconds(50))
      let saved = clip.snapshot()
      defer { if let saved { clip.restore(saved) } }

      clip.write("hunter2", concealed: true)
      #expect(NSPasteboard.general.string(forType: .string) == "hunter2")
      try await Task.sleep(for: .milliseconds(500))
      #expect(NSPasteboard.general.string(forType: .string) == nil)
    }

    @Test("a copy made after a concealed write survives its expiry")
    func concealedExpirySparesNewerCopy() async throws {
      let clip = SystemClipboard(concealedLifetime: .milliseconds(50))
      let saved = clip.snapshot()
      defer { if let saved { clip.restore(saved) } }

      clip.write("hunter2", concealed: true)
      // The user copies something else before the clear fires.
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString("user copy", forType: .string)
      try await Task.sleep(for: .milliseconds(500))
      #expect(NSPasteboard.general.string(forType: .string) == "user copy")
    }

    @Test("a concealed clipboard restored after a paste still clears after its lifetime")
    func restoredConcealedClipboardExpires() async throws {
      // The restore is a write, so it voids the clear pending on the original —
      // Blurt's own leave-behind, or a password manager's timer. Without a fresh
      // clear the restored password would stay on the clipboard indefinitely.
      let clip = SystemClipboard(concealedLifetime: .milliseconds(50))
      // Put the developer's clipboard back with the 90 s default, not 50 ms.
      let saved = SystemClipboard().snapshot()
      defer { if let saved { SystemClipboard().restore(saved) } }

      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString("hunter2", forType: .string)
      pb.setData(Data(), forType: SystemClipboard.concealedType)

      let restore = clip.writeAndPrepareRestore("transcript", concealed: false)
      restore()
      #expect(pb.string(forType: .string) == "hunter2")

      try await Task.sleep(for: .milliseconds(500))
      #expect(pb.string(forType: .string) == nil)
    }
  }
#endif
