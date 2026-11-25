import Foundation
import Testing

@testable import BlurtEngine

// The command code's smaller pieces, one suite per type.

@Suite("DestructiveGuard")
struct DestructiveGuardTests {
  @Test(
    "a button or menu item that deletes, erases or powers off is refused",
    arguments: [
      "Move to Trash", "Empty Trash…", "Delete", "Erase Disk", "Shut Down…", "Restart", "Log Out Alex…",
    ])
  func destructiveLabels(label: String) {
    #expect(DestructiveGuard.isDestructive(label: label))
  }

  @Test(
    "the guard matches whole words, so a lookalike label is allowed",
    arguments: ["Send", "Show Log", "Format", "Restarted Jobs", "Deleted Items Folder"])
  func harmlessLabels(label: String) {
    #expect(!DestructiveGuard.isDestructive(label: label))
  }
}
