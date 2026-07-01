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
