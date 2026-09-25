import SwiftUI

/// The colors the keys draw with — a theme. Six of them, curated: Blurt's
/// ink, and five more cut from the same cloth (the orb's lavender and green,
/// a warm paper, a midnight, a sunset), each contemporary and fun and none of
/// them off-brand. People pick one in the app, Partiful-style, from live
/// previews; the spacing never changes (the iPhone keyboard's own — 6 pt
/// between keys, 11 between rows, 3 at the edges), so a theme changes how the
/// keyboard looks and never how it types. Everything is flat: no drop under a
/// key, no edge, no gloss — a matte surface with matte keys on it.
struct KeyboardPalette: Equatable, Identifiable {
  let id: String
  let name: String
  /// One line for the picker.
  let vibe: String
  let surface: Color
  let key: Color
  let keyDark: Color
  let keyText: Color
  let popupFill: Color

  static let keyGap: CGFloat = 6
  static let rowGap: CGFloat = 11
  static let margin: CGFloat = 3
  /// A touch rounder than the system's 5: flat shapes want it.
  static let keyRadius: CGFloat = 7

  static let ink = KeyboardPalette(
    id: "ink", name: "Ink", vibe: "Blurt's own",
    surface: BlurtBrand.ink, key: BlurtBrand.key, keyDark: BlurtBrand.keyDark, keyText: BlurtBrand.keyText,
    popupFill: BlurtBrand.key)

  static let paper = KeyboardPalette(
    id: "paper", name: "Paper", vibe: "Warm and light",
    surface: Color(hex: 0xEBE8E8), key: .white, keyDark: Color(hex: 0xDEDBDB), keyText: BlurtBrand.ink,
    popupFill: .white)

  static let lavender = KeyboardPalette(
    id: "lavender", name: "Lavender", vibe: "The orb's violet",
    surface: Color(hex: 0x2C2557), key: Color(hex: 0x3F3777), keyDark: Color(hex: 0x352E68),
    keyText: Color(hex: 0xF1EEFF), popupFill: Color(hex: 0x3F3777))

  static let mint = KeyboardPalette(
    id: "mint", name: "Mint", vibe: "The orb's green",
    surface: Color(hex: 0x10231B), key: Color(hex: 0x1E3F31), keyDark: Color(hex: 0x183429),
    keyText: Color(hex: 0xE9F5EE), popupFill: Color(hex: 0x1E3F31))

  static let midnight = KeyboardPalette(
    id: "midnight", name: "Midnight", vibe: "Deep blue-black",
    surface: Color(hex: 0x0E1220), key: Color(hex: 0x1D2440), keyDark: Color(hex: 0x161B33),
    keyText: Color(hex: 0xE8ECFF), popupFill: Color(hex: 0x1D2440))

  static let sunset = KeyboardPalette(
    id: "sunset", name: "Sunset", vibe: "Warm and loud",
    surface: Color(hex: 0x2B1912), key: Color(hex: 0x4B2B20), keyDark: Color(hex: 0x3B2119),
    keyText: Color(hex: 0xFFEFE6), popupFill: Color(hex: 0x4B2B20))

  static let all: [KeyboardPalette] = [ink, paper, lavender, mint, midnight, sunset]

  /// The theme with this id, or Ink for one that no longer exists.
  static func named(_ id: String) -> KeyboardPalette {
    all.first { $0.id == id } ?? ink
  }

  static func == (lhs: KeyboardPalette, rhs: KeyboardPalette) -> Bool { lhs.id == rhs.id }
}

extension Color {
  /// `Color(hex: 0x1D1B16)`.
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }
}

private struct KeyboardPaletteKey: EnvironmentKey {
  static let defaultValue = KeyboardPalette.ink
}

extension EnvironmentValues {
  /// The palette the keys draw with, set once at the root from the model.
  var keyboardPalette: KeyboardPalette {
    get { self[KeyboardPaletteKey.self] }
    set { self[KeyboardPaletteKey.self] = newValue }
  }
}
