import SwiftUI

/// A brand button that can't be pressed yet sits back rather than looking live.
/// A modifier because a `ButtonStyle` can't read the environment itself.
struct FadedWhenDisabled: ViewModifier {
  @Environment(\.isEnabled)
  private var isEnabled

  func body(content: Content) -> some View {
    content.opacity(isEnabled ? 1 : DesignTokens.Metrics.opacityDisabled)
  }
}
