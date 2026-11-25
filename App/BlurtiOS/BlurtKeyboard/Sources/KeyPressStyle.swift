import BlurtDesign
import SwiftUI

/// A key lightens while the finger is on it, the way the system's change
/// shade, instead of the default button dimming.
struct KeyPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .brightness(configuration.isPressed ? DesignTokens.Metrics.opacityPressBrighten : 0)
  }
}
