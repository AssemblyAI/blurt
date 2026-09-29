import SwiftUI

/// The orb dissipating: it swells a little, softens to a haze and is gone —
/// mist, not a pop — and condenses back the same way. `size` scales the haze.
private struct Dissipate: ViewModifier {
  let amount: Double
  let size: CGFloat

  func body(content: Content) -> some View {
    content
      .scaleEffect(1 + 0.25 * amount)
      .blur(radius: size * 0.16 * amount)
      .opacity(1 - amount)
  }
}

extension AnyTransition {
  /// See `Dissipate`.
  static func dissipate(size: CGFloat) -> AnyTransition {
    .modifier(active: Dissipate(amount: 1, size: size), identity: Dissipate(amount: 0, size: size))
  }
}
