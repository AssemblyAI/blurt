import SwiftUI

// macOS 26 introduced the Liquid Glass button styles and `.glassEffect`. The app
// deploys back to macOS 15, so every use of those APIs must be gated behind
// `if #available(macOS 26.0, *)` — both so it compiles against the 15.0
// deployment target and so the newer symbols weak-link (dyld tolerates their
// absence on macOS 15 instead of aborting at launch). These helpers centralize
// the gate + the pre-Tahoe fallback so call sites stay a single modifier.
extension View {
  /// Liquid Glass button style on macOS 26+, falling back to the standard
  /// bordered styles on macOS 15–25. `prominent` maps `.glassProminent` ↔
  /// `.borderedProminent`.
  @ViewBuilder
  func glassButtonStyleCompat(prominent: Bool = false) -> some View {
    if #available(macOS 26.0, *) {
      if prominent {
        buttonStyle(.glassProminent)
      } else {
        buttonStyle(.glass)
      }
    } else {
      if prominent {
        buttonStyle(.borderedProminent)
      } else {
        buttonStyle(.bordered)
      }
    }
  }

  /// Liquid Glass capsule surface on macOS 26+, tinted; falls back to the
  /// pre-Tahoe imitation stack (frosted material + tint overlay, capsule-clipped)
  /// on macOS 15–25 so the overlay pill still reads correctly.
  @ViewBuilder
  func glassCapsuleCompat(tint: Color) -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(.regular.tint(tint), in: .capsule)
    } else {
      background {
        Capsule().fill(.regularMaterial)
        Capsule().fill(tint)
      }
    }
  }
}
