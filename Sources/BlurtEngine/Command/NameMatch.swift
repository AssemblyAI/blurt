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
    guard !query.isEmpty else {
      return nil
    }
    let keyed = candidates.map { (name: $0, key: normalized($0)) }.filter { !$0.key.isEmpty }
    if let exact = keyed.first(where: { $0.key == query }) {
      return exact.name
    }
    let byLength = keyed.sorted { $0.key.count < $1.key.count }
    if let prefix = byLength.first(where: { $0.key.hasPrefix(query) }) {
      return prefix.name
    }
    return byLength.first { $0.key.split(separator: " ").map(String.init).contains(query) }?.name
  }

  /// Folded for comparing: case and accents gone, and the ".app" of a bundle
  /// or the "…" of a menu item that opens a dialog.
  static func normalized(_ name: String) -> String {
    var folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .trimmingCharacters(in: .whitespaces)
    for suffix in [".app", "…", "..."] where folded.hasSuffix(suffix) {
      folded.removeLast(suffix.count)
    }
    return folded.trimmingCharacters(in: .whitespaces)
  }
}
