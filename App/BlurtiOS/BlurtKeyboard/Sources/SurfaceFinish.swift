import SwiftUI

/// The surface's finish. Under the keys: the palette's flat colour and, when
/// the tokens ask for one, a soft vignette toward the edges. Over everything:
/// the brand's film grain, still (one seed, no shimmer — a keyboard has no
/// energy to spare), so every theme reads matte rather than painted. Neither
/// takes a touch.
enum SurfaceFinish {
  struct Ground: View {
    let surface: Color

    var body: some View {
      GeometryReader { geo in
        ZStack {
          surface
          if DesignTokens.Metrics.opacitySurfaceVignette > 0 {
            Rectangle().fill(
              RadialGradient(
                colors: [.clear, .black.opacity(DesignTokens.Metrics.opacitySurfaceVignette)], center: .center,
                startRadius: geo.size.width * DesignTokens.Metrics.surfaceVignetteStart,
                endRadius: geo.size.width * DesignTokens.Metrics.surfaceVignetteEnd))
          }
        }
      }
      .accessibilityHidden(true)
    }
  }

  struct Grain: View {
    var body: some View {
      BlurtiOSGrain(seed: 7)
        .opacity(DesignTokens.Metrics.opacitySurfaceGrain)
        .blendMode(.overlay)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}
