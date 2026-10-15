import SwiftUI
import UIKit

/// Blurt's brand colours, by role. The values live in `Design/tokens.json` and
/// arrive through the generated `DesignTokens`; add a colour to the tokens, not
/// here.
///
/// Two kinds. The app's chrome (`accent`, `page`, `text`, …) adapts to light
/// and dark, from the `app/*-light` and `app/*-dark` token pairs: the same
/// pairs the app's asset catalog is generated from, so system-drawn chrome
/// (the catalog's `AccentColor`) and these agree. The accent is that one pair,
/// `app/accent-*`, which points at Blurt green: repointing it restyles every
/// screen at once.
///
/// The keyboard's surface is fixed per theme instead, the way the Mac's overlay
/// pill is fixed: it floats over whatever app the user is typing in, so it
/// cannot take its cue from that app's appearance, and it must read the same on
/// a white Notes page and a black Messages thread. Everything on it therefore
/// names fixed shades — `errorOrange`, the palette's — never `accent`.
package enum BlurtBrand {
  /// `#E67F36` — the error word. The body stays ink; the word carries the alarm.
  package nonisolated static let errorOrange = DesignTokens.Brand.orange

  /// Green in light, the lifted green in dark: the app's accent.
  package nonisolated static let accent = adaptive(
    DesignTokens.Keyboard.appAccentLight, DesignTokens.Keyboard.appAccentDark)
  /// The page: the design system's warm off-white in light, ink in dark.
  package nonisolated static let page = adaptive(DesignTokens.Keyboard.appPageLight, DesignTokens.Keyboard.appPageDark)
  package nonisolated static let text = adaptive(DesignTokens.Keyboard.appTextLight, DesignTokens.Keyboard.appTextDark)
  /// Eyebrows, captions, secondary lines.
  package nonisolated static let muted = adaptive(
    DesignTokens.Keyboard.appMutedLight, DesignTokens.Keyboard.appMutedDark)
  /// The card: warm tint on paper, a step up from ink in dark, with a hairline.
  package nonisolated static let cardFill = adaptive(
    DesignTokens.Keyboard.appCardFillLight, DesignTokens.Keyboard.appCardFillDark)
  package nonisolated static let cardBorder = adaptive(
    DesignTokens.Keyboard.appCardBorderLight, DesignTokens.Keyboard.appCardBorderDark)
  /// The one accent button per row, and its text.
  package nonisolated static let cta = adaptive(DesignTokens.Keyboard.appCtaLight, DesignTokens.Keyboard.appCtaDark)
  package nonisolated static let ctaText = adaptive(
    DesignTokens.Keyboard.appCtaTextLight, DesignTokens.Keyboard.appCtaTextDark)

  /// A colour that follows the interface style it is drawn in, as an asset
  /// catalog colour does, without needing one: the library carries no catalog,
  /// and the keyboard's bundle has none of the app's.
  private nonisolated static func adaptive(_ light: Color, _ dark: Color) -> Color {
    let light = UIColor(light)
    let dark = UIColor(dark)
    return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
  }
}

extension Color {
  /// `Color(hex: 0x1D1B16)`. `nonisolated` so the generated `DesignTokens`
  /// statics, which are nonisolated too, can call it.
  package nonisolated init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }
}
