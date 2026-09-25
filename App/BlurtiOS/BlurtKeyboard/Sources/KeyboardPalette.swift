import SwiftUI

/// The colors the keys draw with — a theme. The default is the iPhone
/// keyboard's own, light or dark with the app being typed in, so Blurt's keys
/// sit on Apple's globe-and-mic bar as one keyboard and the brand lives in the
/// orb. Then Blurt's ink and five more cut from the same cloth (the orb's
/// lavender and green, a warm paper, a midnight, a sunset), each contemporary
/// and fun and none off-brand, picked in the app Partiful-style from live
/// previews. The spacing never changes (the iPhone keyboard's own — 6 pt
/// between keys, 11 between rows, 3 at the edges, 5 pt corners, a 1 pt drop
/// under every key), so a theme changes how the keyboard looks and never how
/// it types.
struct KeyboardPalette: Equatable, Identifiable {
  let id: String
  let name: String
  /// One line for the picker.
  let vibe: String
  let surface: Color
  let key: Color
  let keyDark: Color
  let keyText: Color
  /// The drop under each key, as the system keyboard draws it.
  let keyShadow: Color
  let popupFill: Color
  /// A faint light edge on each key — what lifts a key off a dark surface;
  /// the light palettes have their drop for that and no edge.
  let keyEdge: Bool

  static let keyGap: CGFloat = 6
  static let rowGap: CGFloat = 11
  static let margin: CGFloat = 3
  static let keyRadius: CGFloat = 5

  /// The iPhone's light keyboard: `#D1D5DB` surface, white keys, `#ADB3BC`
  /// modifiers, a `#898A8D` drop, black legends.
  static let systemLight = KeyboardPalette(
    id: "system", name: "iPhone", vibe: "Matches the iPhone keyboard, light or dark with the app you're in",
    surface: Color(hex: 0xD1D5DB), key: .white, keyDark: Color(hex: 0xADB3BC), keyText: .black,
    keyShadow: Color(hex: 0x898A8D), popupFill: .white, keyEdge: false)

  /// The iPhone's dark keyboard: `#2B2B2B` surface, `#6B6B6B` keys, `#464646`
  /// modifiers, a near-black drop, white legends.
  static let systemDark = KeyboardPalette(
    id: "system", name: "iPhone", vibe: "Matches the iPhone keyboard, light or dark with the app you're in",
    surface: Color(hex: 0x2B2B2B), key: Color(hex: 0x6B6B6B), keyDark: Color(hex: 0x464646), keyText: .white,
    keyShadow: Color(hex: 0x0D0D0D), popupFill: Color(hex: 0x6B6B6B), keyEdge: false)

  static let ink = KeyboardPalette(
    id: "ink", name: "Ink", vibe: "Blurt's own",
    surface: BlurtBrand.ink, key: BlurtBrand.key, keyDark: BlurtBrand.keyDark, keyText: BlurtBrand.keyText,
    keyShadow: Color.black.opacity(0.45), popupFill: BlurtBrand.key, keyEdge: true)

  static let paper = KeyboardPalette(
    id: "paper", name: "Paper", vibe: "Warm and light",
    surface: Color(hex: 0xEBE8E8), key: .white, keyDark: Color(hex: 0xDEDBDB), keyText: BlurtBrand.ink,
    keyShadow: Color.black.opacity(0.18), popupFill: .white, keyEdge: true)

  static let lavender = KeyboardPalette(
    id: "lavender", name: "Lavender", vibe: "The orb's violet",
    surface: Color(hex: 0x2C2557), key: Color(hex: 0x3F3777), keyDark: Color(hex: 0x352E68),
    keyText: Color(hex: 0xF1EEFF), keyShadow: Color.black.opacity(0.4), popupFill: Color(hex: 0x3F3777), keyEdge: true)

  static let mint = KeyboardPalette(
    id: "mint", name: "Mint", vibe: "The orb's green",
    surface: Color(hex: 0x10231B), key: Color(hex: 0x1E3F31), keyDark: Color(hex: 0x183429),
    keyText: Color(hex: 0xE9F5EE), keyShadow: Color.black.opacity(0.4), popupFill: Color(hex: 0x1E3F31), keyEdge: true)

  static let midnight = KeyboardPalette(
    id: "midnight", name: "Midnight", vibe: "Deep blue-black",
    surface: Color(hex: 0x0E1220), key: Color(hex: 0x1D2440), keyDark: Color(hex: 0x161B33),
    keyText: Color(hex: 0xE8ECFF), keyShadow: Color.black.opacity(0.5), popupFill: Color(hex: 0x1D2440), keyEdge: true)

  static let sunset = KeyboardPalette(
    id: "sunset", name: "Sunset", vibe: "Warm and loud",
    surface: Color(hex: 0x2B1912), key: Color(hex: 0x4B2B20), keyDark: Color(hex: 0x3B2119),
    keyText: Color(hex: 0xFFEFE6), keyShadow: Color.black.opacity(0.4), popupFill: Color(hex: 0x4B2B20), keyEdge: true)

  /// The picker's order: the iPhone's own first (shown in the picker's own
  /// appearance), then Blurt's.
  static let all: [KeyboardPalette] = [systemLight, ink, paper, lavender, mint, midnight, sunset]

  /// The theme with this id in the given appearance — only the iPhone theme
  /// has two faces — or the iPhone's for an id that no longer exists.
  static func resolve(_ id: String, dark: Bool) -> KeyboardPalette {
    if id == systemLight.id { return dark ? systemDark : systemLight }
    return all.first { $0.id == id } ?? (dark ? systemDark : systemLight)
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
  static let defaultValue = KeyboardPalette.systemLight
}

extension EnvironmentValues {
  /// The palette the keys draw with, set once at the root from the model.
  var keyboardPalette: KeyboardPalette {
    get { self[KeyboardPaletteKey.self] }
    set { self[KeyboardPaletteKey.self] = newValue }
  }
}
