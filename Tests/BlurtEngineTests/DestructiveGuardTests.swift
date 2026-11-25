import Foundation
import Testing

@testable import BlurtEngine

// The command code's smaller pieces, one suite per type.

@Suite("DestructiveGuard")
struct DestructiveGuardTests {
  @Test("a button or menu item that deletes, erases or powers off is refused, by whole words")
  func destructiveLabels() {
    for label in ["Move to Trash", "Empty Trash…", "Delete", "Erase Disk", "Shut Down…", "Restart", "Log Out Alex…"] {
      #expect(DestructiveGuard.isDestructive(label: label), "\(label)")
    }
    for label in ["Send", "Show Log", "Format", "Restarted Jobs", "Deleted Items Folder"] {
      #expect(!DestructiveGuard.isDestructive(label: label), "\(label)")
    }
  }

  @Test("a phrase spelled as one word is refused too: Shutdown as well as Shut Down")
  func oneWordSpellings() {
    for label in ["Shutdown", "Shutdown…", "Logout"] {
      #expect(DestructiveGuard.isDestructive(label: label), "\(label)")
    }
  }
}
