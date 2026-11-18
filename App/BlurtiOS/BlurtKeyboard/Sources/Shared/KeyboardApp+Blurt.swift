import KeyboardKit

extension KeyboardApp {
  /// Blurt, to KeyboardKit: the free core and nothing else. No licence key,
  /// so nothing Pro is ever unlocked; English only, Apple's own layout; no
  /// App Group handed over, so KeyboardKit's settings stay out of the suite
  /// the app and the keyboard share (`BlurtShared.appGroup`), which is
  /// Blurt's contract and nothing else's. In both targets, as KeyboardKit
  /// asks: the keyboard sets itself up with it, the app reads it.
  static let blurt = KeyboardApp(name: "Blurt", licenseKey: nil, locales: [.english])
}
