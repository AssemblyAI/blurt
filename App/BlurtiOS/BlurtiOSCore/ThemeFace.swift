import Foundation

/// One face of a keyboard theme — its id and whether it is the dark one —
/// with no colours attached: the keyboard model holds a choice, and the shell
/// turns it into a palette (`KeyboardPalette.resolve`).
package nonisolated struct ThemeFace: Equatable, Sendable {
  package var themeID: String
  package var dark: Bool

  package init(themeID: String, dark: Bool) {
    self.themeID = themeID
    self.dark = dark
  }
}
