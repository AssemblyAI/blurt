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

  /// Snapshot/restore the user's clipboard string around a test body so the
  /// suite leaves the real pasteboard as it found it.
  private func withClipboardRestored(_ body: () throws -> Void) rethrows {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    defer {
      pb.clearContents()
      if let saved { pb.setString(saved, forType: .string) }
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

  @Test("currentItems snapshots contents that restore brings back")
  func snapshotRestoreRoundTrips() {
    withClipboardRestored {
      let pb = NSPasteboard.general
      let clip = SystemClipboard()

      pb.clearContents()
      pb.setString("original", forType: .string)
      let snapshot = clip.currentItems()

      clip.setString("overwritten")
      #expect(pb.string(forType: .string) == "overwritten")

      clip.restore(snapshot)
      #expect(pb.string(forType: .string) == "original")
    }
  }

  @Test("snapshot/restore preserves every representation of multi-type, multi-item contents")
  func multiTypeSnapshotRoundTrips() {
    // The reason `SendablePasteboardItem` keys data by pasteboard *type*: a copy
    // of styled text carries several representations (plain string + RTF), and
    // the restore must bring all of them back — a string-only round trip would
    // silently downgrade the user's clipboard to plain text.
    withClipboardRestored {
      let pb = NSPasteboard.general
      let clip = SystemClipboard()

      let styled = NSPasteboardItem()
      styled.setString("styled", forType: .string)
      styled.setData(Data("{\\rtf1 styled}".utf8), forType: .rtf)
      let plain = NSPasteboardItem()
      plain.setString("second item", forType: .string)
      pb.clearContents()
      pb.writeObjects([styled, plain])
      let snapshot = clip.currentItems()

      clip.setString("overwritten")
      clip.restore(snapshot)

      let restored = pb.pasteboardItems ?? []
      #expect(restored.count == 2)
      #expect(restored.first?.string(forType: .string) == "styled")
      #expect(restored.first?.data(forType: .rtf) == Data("{\\rtf1 styled}".utf8))
      #expect(restored.last?.string(forType: .string) == "second item")
    }
  }

  @Test("restore of an empty snapshot leaves the cleared pasteboard empty")
  func restoreEmptyIsNoOp() {
    withClipboardRestored {
      let pb = NSPasteboard.general
      let clip = SystemClipboard()

      pb.clearContents()  // an empty pasteboard has no items to snapshot
      let empty = clip.currentItems()
      clip.setString("temp")
      clip.restore(empty)

      #expect(pb.string(forType: .string) == nil)
    }
  }
}
