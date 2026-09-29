import SwiftUI

extension View {
  /// The cap under a key's legend: the palette's fill at the corner radius and
  /// nothing else — flat. No drop, no edge, no gloss.
  func keyCap(_ fill: Color) -> some View {
    background(fill, in: RoundedRectangle(cornerRadius: KeyboardPalette.keyRadius))
  }
}

/// A key lightens while the finger is on it, the way the system's change
/// shade, instead of the default button dimming.
struct KeyPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .brightness(configuration.isPressed ? DesignTokens.Metrics.opacityPressBrighten : 0)
      .animation(.easeOut(duration: DesignTokens.Motion.keyPress), value: configuration.isPressed)
  }
}
