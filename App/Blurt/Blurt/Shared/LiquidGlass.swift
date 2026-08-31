import SwiftUI

// macOS 26 introduced the Liquid Glass button styles and `.glassEffect`. The app
// deploys back to macOS 15, so every use of those APIs must be gated behind
// `if #available(macOS 26.0, *)` — both so it compiles against the 15.0
// deployment target and so the newer symbols weak-link (dyld tolerates their
// absence on macOS 15 instead of aborting at launch). These helpers centralize
// the gate + the pre-Tahoe fallback so call sites stay a single modifier.
extension View {
  /// Liquid Glass button style on macOS 26+, falling back to the standard
  /// bordered styles on macOS 15–25.
  ///
  /// `prominent` is the exception: it stays `.borderedProminent` on every
  /// version. `.glassProminent` tints its *material* rather than filling with
  /// the accent, which lands a filled button at `#007723` while the wordmark
  /// and every plain accent use render `#01762F` — close, but visibly less
  /// blue side by side. `.borderedProminent` paints the accent flat, so the
  /// filled buttons match the brand exactly. It's still a system style, so
  /// hover/press chrome, sizing and the accessibility fallbacks all come from
  /// AppKit rather than a hand-rolled fill.
  @ViewBuilder
  func glassButtonStyleCompat(prominent: Bool = false) -> some View {
    if prominent {
      buttonStyle(.borderedProminent)
    } else if #available(macOS 26.0, *) {
      buttonStyle(.glass)
    } else {
      buttonStyle(.bordered)
    }
  }
}
