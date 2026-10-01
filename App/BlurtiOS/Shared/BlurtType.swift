import SwiftUI
import UIKit

/// The brand's faces, by the names the bundle registered them under
/// (`DesignTokens.Fonts`, PostScript names from the files in `Design/fonts`).
/// The keyboard uses the mono; the app's serif and body faces join when its
/// screens move onto the brand. Fixed point sizes throughout, as the system
/// keyboard's are — no Dynamic Type. `Font.custom` falls back to the system font in silence when a name
/// is wrong, so `missing()` says which names the bundle doesn't know; a test
/// pins it empty and debug builds assert it once.
enum BlurtType {
  enum MonoWeight {
    case light
    case regular
    case medium
  }

  private typealias Fonts = DesignTokens.Fonts

  /// Modern Gothic Mono: eyebrows, CTAs, the keyboard's word labels.
  nonisolated static func mono(_ size: CGFloat, weight: MonoWeight = .regular) -> Font {
    Font.custom(monoName(weight), fixedSize: size)
  }

  /// Oceanic Text: the app's serif headlines, sentence case, tight.
  nonisolated static func heading(_ size: CGFloat) -> Font { Font.custom(Fonts.headingRegular, fixedSize: size) }

  /// UN 11ST: the app's body text.
  nonisolated static func body(_ size: CGFloat, bold: Bool = false) -> Font {
    Font.custom(bold ? Fonts.bodyBold : Fonts.bodyRegular, fixedSize: size)
  }

  private nonisolated static func monoName(_ weight: MonoWeight) -> String {
    switch weight {
    case .light: Fonts.monoLight
    case .regular: Fonts.monoRegular
    case .medium: Fonts.monoMedium
    }
  }

  nonisolated static let names = [
    Fonts.monoLight, Fonts.monoRegular, Fonts.monoMedium, Fonts.headingRegular, Fonts.bodyRegular, Fonts.bodyBold,
  ]

  /// The names this process cannot load: empty when the bundle's
  /// `UIAppFonts` and `Design/fonts` agree with the tokens.
  nonisolated static func missing() -> [String] {
    names.filter { UIFont(name: $0, size: 12) == nil }
  }
}
