import SwiftUI

/// The colors a layout draws its surface and keys with. Two looks: Blurt's
/// own (the ink surface, `BlurtBrand`) and the iPhone's default keyboard,
/// which follows the app being typed in between its light and dark palettes.
/// The status pill and the orb are Blurt's in both; the look is about the
/// keys. Spacing lives on `KeyboardTheme`, shared with the app for the
/// layout heights.
struct KeyboardPalette: Equatable {
  var surface: Color
  var key: Color
  var keyDark: Color
  var keyText: Color
  /// The 1 pt drop the system keyboard gives every key; nil for the flat ink look.
  var keyShadow: Color?
  var keyRadius: CGFloat
  var popupFill: Color

  static let blurt = KeyboardPalette(
    surface: BlurtBrand.ink, key: BlurtBrand.key, keyDark: BlurtBrand.keyDark, keyText: BlurtBrand.keyText,
    keyShadow: nil, keyRadius: 6, popupFill: BlurtBrand.key)

  /// The iPhone's light keyboard: `#D1D5DB` surface, white keys, `#ADB3BC`
  /// modifiers, a `#898A8D` drop under each key.
  static let systemLight = KeyboardPalette(
    surface: Color(red: 209 / 255, green: 213 / 255, blue: 219 / 255), key: .white,
    keyDark: Color(red: 173 / 255, green: 179 / 255, blue: 188 / 255), keyText: .black,
    keyShadow: Color(red: 137 / 255, green: 138 / 255, blue: 141 / 255), keyRadius: 5, popupFill: .white)

  /// The iPhone's dark keyboard: `#2B2B2B` surface, `#6B6B6B` keys, `#464646`
  /// modifiers, a near-black drop.
  static let systemDark = KeyboardPalette(
    surface: Color(red: 43 / 255, green: 43 / 255, blue: 43 / 255),
    key: Color(red: 107 / 255, green: 107 / 255, blue: 107 / 255),
    keyDark: Color(red: 70 / 255, green: 70 / 255, blue: 70 / 255), keyText: .white,
    keyShadow: Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255), keyRadius: 5,
    popupFill: Color(red: 107 / 255, green: 107 / 255, blue: 107 / 255))

  static func resolve(theme: KeyboardTheme, dark: Bool) -> KeyboardPalette {
    switch theme {
    case .blurt: .blurt
    case .system: dark ? .systemDark : .systemLight
    }
  }
}

private struct KeyboardPaletteKey: EnvironmentKey {
  static let defaultValue = KeyboardPalette.blurt
}

extension EnvironmentValues {
  /// The palette the keys draw with, set once at the root from the model.
  var keyboardPalette: KeyboardPalette {
    get { self[KeyboardPaletteKey.self] }
    set { self[KeyboardPaletteKey.self] = newValue }
  }
}
