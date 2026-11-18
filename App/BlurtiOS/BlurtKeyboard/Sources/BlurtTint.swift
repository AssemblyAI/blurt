import BlurtDesign
import KeyboardKit
import SwiftUI

/// The two brand colours left on Apple's keyboard: the signal green (a
/// recording, the caret, a saved term) and the notice orange (the status
/// line, a failure), each in the host's scheme. Everything else the keyboard
/// draws takes KeyboardKit's own colours, so the keys and the bar read as
/// Apple's.
enum BlurtTint {
  static func signal(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? DesignTokens.Themes.darkSignal : DesignTokens.Themes.lightSignal
  }

  static func notice(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? DesignTokens.Themes.darkNotice : DesignTokens.Themes.lightNotice
  }

  /// A key's legend on Apple's keyboard: the words and glyphs in the bar.
  static func legend(_ scheme: ColorScheme) -> Color { Color.keyboardButtonForeground(for: scheme) }

  /// A key's cap on Apple's keyboard: the term field and the chip.
  static func field(_ scheme: ColorScheme) -> Color { Color.keyboardButtonBackground(for: scheme) }

  /// The hairline under a key on Apple's keyboard: the field's and the chip's edge.
  static func edge(_ scheme: ColorScheme) -> Color { Color.keyboardButtonShadow(for: scheme) }
}
