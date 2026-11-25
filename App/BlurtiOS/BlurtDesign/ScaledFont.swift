import SwiftUI

/// A role's font at a token size scaled by the user's text size: `@ScaledMetric`
/// re-reads the setting, so a change in Settings reaches the screen at once.
/// Applied through `BlurtType`'s `View` modifiers (`bodyFont`, `headingFont`,
/// `monoFont`), never directly.
struct ScaledFont: ViewModifier {
  @ScaledMetric private var size: CGFloat
  private let font: (CGFloat) -> Font

  init(size: CGFloat, relativeTo style: Font.TextStyle, font: @escaping (CGFloat) -> Font) {
    _size = ScaledMetric(wrappedValue: size, relativeTo: style)
    self.font = font
  }

  func body(content: Content) -> some View {
    content.font(font(size))
  }
}
