import BlurtDesign
import SwiftUI

/// The colours the keys draw with: the brand's two faces. The keyboard follows
/// the field it is typing into — ink with the brand's film grain when the
/// host app is dark, warm paper when it is light — so Blurt sits on any app
/// as one keyboard, on the brand and off Apple's grey. The spacing never
/// changes (the iPhone keyboard's own — 6 pt between keys, 11 between rows,
/// 3 at the edges), so a face changes how the keyboard looks and never how it
/// types. The keys are flat: one colour, no drop, no edge, no gloss.
///
/// One theme for now, with two faces. The curated themes come back later as
/// value sets through the same shape: `all` is the picker's list, `resolve`
/// the keyboard's lookup, and neither needs to change for a third entry.
struct KeyboardPalette: Equatable, Identifiable {
  enum Face: String {
    case light
    case dark
  }

  let id: String
  let face: Face
  let name: String
  /// One line for the picker.
  let vibe: String
  let surface: Color
  let key: Color
  let keyDark: Color
  let keyText: Color
  /// The word labels (123, ABC, return, space) in mono, and the + at rest:
  /// a step quieter than a letter.
  let keyTextSecondary: Color
  /// The voice on this surface: the wave, the caret, the saved check. The
  /// brand green that reads on it — the wordmark's on paper, the lifted one
  /// on ink.
  let signal: Color
  let popupFill: Color
  /// The key-term field and its hairline.
  let field: Color
  let fieldBorder: Color
  /// The error word, the cancel ×, the Full Access note: orange on both faces.
  let notice: Color
  /// How much film grain lies over the surface: the brand's texture, matte.
  let grain: Double
  /// The keys when the host wraps the keyboard in its own material (iOS 26's
  /// Liquid Glass apps: Messages, Notes, Safari) and the surface goes clear:
  /// colours that read on the system's light or dark material.
  let containerKey: Color
  let containerKeyModifier: Color
  /// The host's material under a clear surface, as the gallery and the home
  /// screen stand in for it (the system's own keyboard colour, measured).
  let material: Color

  static let rowGap = DesignTokens.Metrics.rowGap
  static let margin = DesignTokens.Metrics.marginSide
  static let keyRadius = DesignTokens.Metrics.keyRadius

  private typealias Themes = DesignTokens.Themes

  /// The brand theme's id, and what any unknown id resolves to.
  static let brandID = "blurt"
  private static let brandName = "Blurt"
  private static let brandVibe = "Ink or paper, with the app you're in"

  /// The light face: paper `#ECEBE5`, white keys, `#DAD7CB` modifiers, ink
  /// legends, the wordmark green.
  static let brandLight = KeyboardPalette(
    id: brandID, face: .light, name: brandName, vibe: brandVibe,
    surface: Themes.lightSurface, key: Themes.lightKey, keyDark: Themes.lightKeyModifier,
    keyText: Themes.lightLegend, keyTextSecondary: Themes.lightLegendSecondary, signal: Themes.lightSignal,
    popupFill: Themes.lightPopup, field: Themes.lightField, fieldBorder: Themes.lightFieldBorder,
    notice: Themes.lightNotice, grain: DesignTokens.Metrics.opacityGrainLight,
    containerKey: Themes.lightContainerKey, containerKeyModifier: Themes.lightContainerKeyModifier,
    material: Themes.lightMaterial)

  /// The dark face: ink `#1D1B16`, `#33302A` keys, `#26231E` modifiers, warm
  /// white legends, the lifted green.
  static let brandDark = KeyboardPalette(
    id: brandID, face: .dark, name: brandName, vibe: brandVibe,
    surface: Themes.darkSurface, key: Themes.darkKey, keyDark: Themes.darkKeyModifier,
    keyText: Themes.darkLegend, keyTextSecondary: Themes.darkLegendSecondary, signal: Themes.darkSignal,
    popupFill: Themes.darkPopup, field: Themes.darkField, fieldBorder: Themes.darkFieldBorder,
    notice: Themes.darkNotice, grain: DesignTokens.Metrics.opacityGrainDark,
    containerKey: Themes.darkContainerKey, containerKeyModifier: Themes.darkContainerKeyModifier,
    material: Themes.darkMaterial)

  /// The picker's list, one entry per theme (a theme's two faces share an id).
  static let all: [KeyboardPalette] = [brandLight]

  /// The theme with this id in the given appearance, or the brand's for an id
  /// that no longer exists (the old `system` default, a retired theme).
  static func resolve(_ id: String, dark: Bool) -> KeyboardPalette {
    // One theme so far: a known id and a retired one land in the same place.
    guard all.contains(where: { $0.id == id }) else { return dark ? brandDark : brandLight }
    return dark ? brandDark : brandLight
  }

  /// What stands under the keyboard where the host's material would be
  /// (the gallery, a preview): the face's surface when it is painted, else
  /// the material.
  var standIn: Color { KeyboardRootView.paintsSurface ? surface : material }

  /// A key's fill: the face's, or the container's when the host's material
  /// is the surface.
  func keyFill(modifier: Bool, inContainer: Bool) -> Color {
    if inContainer { return modifier ? containerKeyModifier : containerKey }
    return modifier ? keyDark : key
  }

  static func == (lhs: KeyboardPalette, rhs: KeyboardPalette) -> Bool { lhs.id == rhs.id && lhs.face == rhs.face }
}

private struct KeyboardInContainerKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// Whether the host wraps the keyboard in its own material (iOS 26's
  /// Liquid Glass apps inset a third-party keyboard inside a rounded
  /// container nothing can paint over): the surface goes clear and the keys
  /// take the palette's container colours, so there is no band of a
  /// different grey above the keyboard.
  var keyboardInContainer: Bool {
    get { self[KeyboardInContainerKey.self] }
    set { self[KeyboardInContainerKey.self] = newValue }
  }
}

private struct KeyboardPaletteKey: EnvironmentKey {
  static let defaultValue = KeyboardPalette.brandLight
}

extension EnvironmentValues {
  /// The palette the keys draw with, set once at the root from the model.
  var keyboardPalette: KeyboardPalette {
    get { self[KeyboardPaletteKey.self] }
    set { self[KeyboardPaletteKey.self] = newValue }
  }
}
