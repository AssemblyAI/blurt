import SwiftUI

/// The colors and spacing the keys draw with. The spacing is the iPhone
/// keyboard's own — 6 pt between keys, 11 pt between rows, 3 pt at the
/// edges, 5 pt corners, a 1 pt drop under every key — so nobody's fingers
/// are thrown off; the colours are Blurt's (`BlurtBrand`). One palette for
/// now; themes are a later feature, and this is the seam they plug into.
struct KeyboardPalette: Equatable {
  var surface: Color
  var key: Color
  var keyDark: Color
  var keyText: Color
  /// The drop under each key, as the system keyboard draws it.
  var keyShadow: Color
  var popupFill: Color

  static let keyGap: CGFloat = 6
  static let rowGap: CGFloat = 11
  static let margin: CGFloat = 3
  static let keyRadius: CGFloat = 5

  static let blurt = KeyboardPalette(
    surface: BlurtBrand.ink, key: BlurtBrand.key, keyDark: BlurtBrand.keyDark, keyText: BlurtBrand.keyText,
    keyShadow: Color.black.opacity(0.45), popupFill: BlurtBrand.key)
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
