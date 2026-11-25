import Foundation

/// The planner's instruction forbids deleting files, emptying the trash and
/// shutting down; this is that rule in code, so a plan that ignores it still
/// can't. Checked on the chord as parsed, and on the button or menu item as
/// matched on screen (a request for "Empty" can match "Empty Trash…").
enum DestructiveGuard {
  /// Phrases that mark a button or menu item as deleting, erasing or powering
  /// off, matched as whole words of its folded label: "Log Out" is refused,
  /// "Show Log" isn't.
  /// English only, US and British ("Move to Bin", "Sign Out"): a Mac set to
  /// another language names these its own way, and the guard won't see them —
  /// the planner's instruction still forbids them there.
  static let phrases = [
    "delete", "trash", "bin", "erase", "shut down", "restart", "log out", "logout", "log off", "sign out",
  ]

  /// ⌘ with delete or forward delete: Move to Trash, Empty Trash and Delete
  /// Immediately in the Finder, and the same family elsewhere. And ⌘⇧Q, with
  /// or without ⌥: Log Out — the ⌥ form skips the confirmation. The power
  /// and eject chords need no entry: neither key is one a plan can name
  /// (`KeyChord`'s tables), so they're refused as unknown.
  static func isDestructive(_ chord: KeyChord) -> Bool {
    switch chord.key {
    case .code(let code):
      chord.modifiers.contains(.command) && [0x33, 0x75].contains(code)

    case .character(let character):
      character == "q" && chord.modifiers.isSuperset(of: [.command, .shift])
    }
  }

  static func isDestructive(label: String) -> Bool {
    let words = NameMatch.normalized(label).split { !$0.isLetter }.joined(separator: " ")
    return phrases.contains { " \(words) ".contains(" \($0) ") }
  }
}
