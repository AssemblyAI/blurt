import SwiftUI

/// The colors the keys draw with — a theme. The default is the iPhone
/// keyboard's own, light or dark with the app being typed in, so Blurt's keys
/// sit on Apple's globe-and-mic bar as one keyboard and the brand lives in the
/// orb. Then Blurt's ink and five more cut from the same cloth (the orb's
/// lavender and green, a warm paper, a midnight, a sunset), each contemporary
/// and fun and none off-brand, picked in the app Partiful-style from live
/// previews. The spacing never changes (the iPhone keyboard's own — 6 pt
/// between keys, 11 between rows, 3 at the edges), so a theme changes how
/// the keyboard looks and never how it types. The keys are flat: one colour
/// at 8 pt corners, no drop, no edge, no gloss.
struct KeyboardPalette: Equatable, Identifiable {
  let id: String
  let name: String
  /// One line for the picker.
  let vibe: String
  let surface: Color
  let key: Color
  let keyDark: Color
  let keyText: Color
  /// The voice on this surface: the wave while recording. The brand green
  /// that reads on it — the wordmark's on light, the lifted one on dark.
  let signal: Color
  let popupFill: Color

  static let keyGap = DesignTokens.Metrics.keyGap
  static let rowGap = DesignTokens.Metrics.rowGap
  static let margin = DesignTokens.Metrics.marginSide
  static let keyRadius = DesignTokens.Metrics.keyRadius

  private typealias Themes = DesignTokens.Themes

  /// The iPhone's light keyboard: `#D1D5DB` surface, white keys, `#ADB3BC`
  /// modifiers, black legends.
  static let systemLight = KeyboardPalette(
    id: "system", name: "iPhone", vibe: "Matches the iPhone keyboard, light or dark with the app you're in",
    surface: Themes.systemLightSurface, key: Themes.systemLightKey, keyDark: Themes.systemLightKeyModifier,
    keyText: Themes.systemLightLegend, signal: Themes.systemLightSignal, popupFill: Themes.systemLightPopup)

  /// The iPhone's dark keyboard: `#2B2B2B` surface, `#6B6B6B` keys, `#464646`
  /// modifiers, white legends.
  static let systemDark = KeyboardPalette(
    id: "system", name: "iPhone", vibe: "Matches the iPhone keyboard, light or dark with the app you're in",
    surface: Themes.systemDarkSurface, key: Themes.systemDarkKey, keyDark: Themes.systemDarkKeyModifier,
    keyText: Themes.systemDarkLegend, signal: Themes.systemDarkSignal, popupFill: Themes.systemDarkPopup)

  static let ink = KeyboardPalette(
    id: "ink", name: "Ink", vibe: "Blurt's own",
    surface: Themes.inkSurface, key: Themes.inkKey, keyDark: Themes.inkKeyModifier, keyText: Themes.inkLegend,
    signal: Themes.inkSignal, popupFill: Themes.inkPopup)

  static let paper = KeyboardPalette(
    id: "paper", name: "Paper", vibe: "Warm and light",
    surface: Themes.paperSurface, key: Themes.paperKey, keyDark: Themes.paperKeyModifier, keyText: Themes.paperLegend,
    signal: Themes.paperSignal, popupFill: Themes.paperPopup)

  static let lavender = KeyboardPalette(
    id: "lavender", name: "Lavender", vibe: "The orb's violet",
    surface: Themes.lavenderSurface, key: Themes.lavenderKey, keyDark: Themes.lavenderKeyModifier,
    keyText: Themes.lavenderLegend, signal: Themes.lavenderSignal, popupFill: Themes.lavenderPopup)

  static let mint = KeyboardPalette(
    id: "mint", name: "Mint", vibe: "The orb's green",
    surface: Themes.mintSurface, key: Themes.mintKey, keyDark: Themes.mintKeyModifier,
    keyText: Themes.mintLegend, signal: Themes.mintSignal, popupFill: Themes.mintPopup)

  static let midnight = KeyboardPalette(
    id: "midnight", name: "Midnight", vibe: "Deep blue-black",
    surface: Themes.midnightSurface, key: Themes.midnightKey, keyDark: Themes.midnightKeyModifier,
    keyText: Themes.midnightLegend, signal: Themes.midnightSignal, popupFill: Themes.midnightPopup)

  static let sunset = KeyboardPalette(
    id: "sunset", name: "Sunset", vibe: "Warm and loud",
    surface: Themes.sunsetSurface, key: Themes.sunsetKey, keyDark: Themes.sunsetKeyModifier,
    keyText: Themes.sunsetLegend, signal: Themes.sunsetSignal, popupFill: Themes.sunsetPopup)

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
  /// `Color(hex: 0x1D1B16)`. `nonisolated` so the generated `DesignTokens`
  /// statics, which are nonisolated too, can call it.
  nonisolated init(hex: UInt32) {
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
