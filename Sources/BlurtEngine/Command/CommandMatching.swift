import Foundation

/// Picking the app, button or menu item a spoken name means, apart from
/// the system so it's tested.
enum NameMatch {
  /// The candidate `name` most likely means: the same name ignoring case,
  /// accents and a trailing ellipsis, else the shortest that starts with it
  /// ("visual studio" is "Visual Studio Code"), else the shortest with it as
  /// a whole word ("chrome" → "Google Chrome"). Nil when none is close.
  static func best(for name: String, among candidates: [String]) -> String? {
    let query = normalized(name)
    guard !query.isEmpty else { return nil }
    let keyed = candidates.map { (name: $0, key: normalized($0)) }.filter { !$0.key.isEmpty }
    if let exact = keyed.first(where: { $0.key == query }) { return exact.name }
    let byLength = keyed.sorted { $0.key.count < $1.key.count }
    if let prefix = byLength.first(where: { $0.key.hasPrefix(query) }) { return prefix.name }
    return byLength.first { $0.key.split(separator: " ").map(String.init).contains(query) }?.name
  }

  /// Folded for comparing: case and accents gone, and the ".app" of a bundle
  /// or the "…" of a menu item that opens a dialog.
  static func normalized(_ name: String) -> String {
    var name = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespaces)
    for suffix in [".app", "…", "..."] where name.hasSuffix(suffix) {
      name.removeLast(suffix.count)
    }
    return name.trimmingCharacters(in: .whitespaces)
  }
}

/// Finding the element a `press_button` step names in an Accessibility tree,
/// over any node type so the search is tested without one.
enum ElementSearch {
  /// The most elements a search looks at: a busy window (a mail list, a
  /// spreadsheet) can hold tens of thousands, each a round trip to its app.
  static let maxElements = 3_000

  /// The pressable node whose label best matches `name` (`NameMatch`),
  /// visiting breadth first (`ScreenSnapshot.entries`), so of two the same
  /// label the one nearer the window's top level wins. An exact match ends the
  /// search there; `shouldStop` ends it early otherwise (the read's deadline).
  static func best<Node>(
    named name: String, from root: Node, children: (Node) -> [Node], labels: (Node) -> [String],
    pressable: (Node) -> Bool, limit: Int = maxElements, shouldStop: () -> Bool = { false }
  ) -> Node? {
    let query = NameMatch.normalized(name)
    var exact = false
    let candidates = ScreenSnapshot.entries(
      from: root, children: children,
      describe: { node -> (kind: String, label: String)? in
        // One entry per node: its label that matches best. Labels first — they
        // mostly come from a read already made — and `pressable`, a round trip
        // of its own, only for a node whose name matches at all.
        guard let label = NameMatch.best(for: name, among: labels(node)), pressable(node) else { return nil }
        exact = exact || NameMatch.normalized(label) == query
        return ("", label)
      }, visitLimit: limit, keepLimit: .max, shouldStop: { exact || shouldStop() })
    guard let label = NameMatch.best(for: name, among: candidates.map(\.label)) else { return nil }
    return candidates.first { $0.label == label }?.node
  }
}

/// Whether an app owns the window on top, from the window server's on-screen
/// list, apart from it so the rule is tested.
enum WindowOrder {
  struct Window: Equatable {
    let owner: Int
    let layer: Int
  }

  /// `windows` front to back, as `CGWindowListCopyWindowInfo` lists them.
  /// Only the normal layer (0) counts: the menu bar, the Dock and floating
  /// panels — Blurt's pill among them — sit above it. An app with no normal
  /// window on screen (its last one closed) passes: there's nothing of its to
  /// wait for.
  static func isFrontmost(_ pid: Int, in windows: [Window]) -> Bool {
    let normal = windows.filter { $0.layer == 0 }
    guard normal.contains(where: { $0.owner == pid }) else { return true }
    return normal.first?.owner == pid
  }
}

/// The planner's instruction forbids deleting files, emptying the trash and
/// shutting down; this is that rule in code, so a plan that ignores it still
/// can't. Checked on the chord as parsed, and on the button or menu item as
/// matched on screen (a request for "Empty" can match "Empty Trash…").
enum DestructiveGuard {
  /// ⌘ with delete or forward delete: Move to Trash, Empty Trash and Delete
  /// Immediately in the Finder, and the same family elsewhere. And ⌘⇧Q, with
  /// or without ⌥: Log Out — the ⌥ form skips the confirmation. The power
  /// and eject chords need no entry: neither key is one a plan can name
  /// (`KeyChord`'s tables), so they're refused as unknown.
  static func isDestructive(_ chord: KeyChord) -> Bool {
    switch chord.key {
    case .code(let code): chord.modifiers.contains(.command) && [0x33, 0x75].contains(code)
    case .character(let character): character == "q" && chord.modifiers.isSuperset(of: [.command, .shift])
    }
  }

  /// Phrases that mark a button or menu item as deleting, erasing or powering
  /// off, matched as whole words of its folded label: "Log Out" is refused,
  /// "Show Log" isn't.
  /// English only, US and British ("Move to Bin", "Sign Out"): a Mac set to
  /// another language names these its own way, and the guard won't see them —
  /// the planner's instruction still forbids them there.
  static let phrases = [
    "delete", "trash", "bin", "erase", "shut down", "restart", "log out", "logout", "log off", "sign out",
  ]

  static func isDestructive(label: String) -> Bool {
    let words = NameMatch.normalized(label).split { !$0.isLetter }.joined(separator: " ")
    return phrases.contains { " \(words) ".contains(" \($0) ") }
  }
}
