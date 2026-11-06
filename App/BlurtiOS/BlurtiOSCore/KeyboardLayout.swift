/// Which keyboard the user chose. All three share the same plumbing underneath;
/// they differ only in how much keyboard sits around the mic.
package nonisolated enum KeyboardLayout: String, CaseIterable, Codable, Sendable, Identifiable {
  /// A slim strip: the mic, delete, return and the globe. Typing letters means
  /// switching back to the system keyboard.
  case slimBar
  /// A big orb with cancel beside it and a few keys — the shape Wispr and
  /// Aqua ship — that swipes to the full keyboard.
  case panel
  /// A complete keyboard with the mic as the main key, so nobody has to switch
  /// keyboards to fix a typo.
  case full

  package var id: String { rawValue }

  package var title: String {
    switch self {
    case .slimBar: "Mic bar"
    case .panel: "Mic panel"
    case .full: "Full keyboard"
    }
  }

  package var summary: String {
    switch self {
    case .slimBar: "Just the mic and a few keys. Switch keyboards to type."
    case .panel: "A big mic with status and cancel. Swipe sideways for the full keyboard, and back."
    case .full: "Every letter key, with the orb above them."
    }
  }
}
