import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// The colours the keys draw with: the brand's two faces, and — on the
/// classic generation — the iPhone's own. The keyboard follows the field it
/// is typing into: ink with the brand's film grain when the host app is
/// dark, warm paper when it is light — so Blurt sits on any app as one
/// keyboard, on the brand and off Apple's grey. The spacing is the profile's
/// (`KeyboardProfile`), so a face changes how the keyboard looks and never
/// how it types. The keys are flat: one colour, no drop, no edge, no gloss.
///
/// Two themes. The brand, with its two faces, on every phone; and on the
/// classic generation (iOS 18, or an iOS 26 host with no container) the
/// `system` theme — Apple's classic grey, white and `#ADB3BC` modifiers, the
/// dark keys `#6B6B6B` on `#2B2B2B` — which is the default there, the brand
/// one row away in the picker. The curated themes come back later as value
/// sets through the same shape: `all(for:)` is the picker's list, `resolve`
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

  /// The system theme's id: the store's default, so a phone that never
  /// picked a theme gets the iPhone's own keys on the classic generation.
  static let systemID = SharedStore.defaultThemeID
  private static let systemName = "System"
  private static let systemVibe = "The iPhone's own keys"

  /// The iPhone's classic light keyboard: `#D1D5DB` under white keys and
  /// `#ADB3BC` modifiers, black legends, no grain.
  static let systemLight = KeyboardPalette(
    id: systemID, face: .light, name: systemName, vibe: systemVibe,
    surface: Themes.systemLightSurface, key: Themes.systemLightKey, keyDark: Themes.systemLightKeyModifier,
    keyText: Themes.systemLightLegend, keyTextSecondary: Themes.systemLightLegendSecondary,
    signal: Themes.systemLightSignal, popupFill: Themes.systemLightPopup, field: Themes.systemLightField,
    fieldBorder: Themes.systemLightFieldBorder, notice: Themes.systemLightNotice, grain: 0,
    containerKey: Themes.systemLightContainerKey, containerKeyModifier: Themes.systemLightContainerKeyModifier,
    material: Themes.systemLightMaterial)

  /// The iPhone's classic dark keyboard: `#2B2B2B` under `#6B6B6B` keys and
  /// `#464646` modifiers, white legends, no grain.
  static let systemDark = KeyboardPalette(
    id: systemID, face: .dark, name: systemName, vibe: systemVibe,
    surface: Themes.systemDarkSurface, key: Themes.systemDarkKey, keyDark: Themes.systemDarkKeyModifier,
    keyText: Themes.systemDarkLegend, keyTextSecondary: Themes.systemDarkLegendSecondary,
    signal: Themes.systemDarkSignal, popupFill: Themes.systemDarkPopup, field: Themes.systemDarkField,
    fieldBorder: Themes.systemDarkFieldBorder, notice: Themes.systemDarkNotice, grain: 0,
    containerKey: Themes.systemDarkContainerKey, containerKeyModifier: Themes.systemDarkContainerKeyModifier,
    material: Themes.systemDarkMaterial)

  /// The picker's list for a generation, one entry per theme (a theme's two
  /// faces share an id): on classic the system theme first, then the brand;
  /// on glass the brand alone — the host's material is the system look there.
  static func all(for generation: KeyboardProfile.Generation) -> [KeyboardPalette] {
    switch generation {
    case .classic: [systemLight, brandLight]
    case .glass: [brandLight]
    }
  }

  /// The theme with this id in the given appearance on this generation, or
  /// the brand's for an id the generation does not offer (`system` on glass,
  /// a retired theme).
  static func resolve(_ id: String, dark: Bool, generation: KeyboardProfile.Generation) -> KeyboardPalette {
    if generation == .classic, id == systemID { return dark ? systemDark : systemLight }
    return dark ? brandDark : brandLight
  }

  /// What stands under the keyboard where the host's material would be
  /// (the gallery, a preview): the face's surface when it is painted, else
  /// the material.
  func standIn(painted: Bool) -> Color { painted ? surface : material }

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

private struct KeyboardProfileKey: EnvironmentKey {
  static let defaultValue = KeyboardProfile.standIn(width: DesignTokens.Metrics.glassReferenceWidth)
}

extension EnvironmentValues {
  /// The keyboard's numbers for this phone and OS (`KeyboardProfile`), set
  /// once at the root: the key height and corner, the gaps, the margins.
  var keyboardProfile: KeyboardProfile {
    get { self[KeyboardProfileKey.self] }
    set { self[KeyboardProfileKey.self] = newValue }
  }
}
