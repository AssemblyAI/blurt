import BlurtDesign
import SwiftUI

/// The surface's finish. Under the keys: the face's flat colour and, when
/// the tokens ask for one, a soft vignette toward the edges. Over everything:
/// the brand's film grain, still (one seed, no shimmer — a keyboard has no
/// energy to spare), heavier on ink than on paper, so both faces read matte
/// rather than painted. Neither takes a touch.
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
    @Environment(\.keyboardPalette) private var palette

    var body: some View {
      FilmGrain(seed: 7)
        .opacity(palette.grain)
        .blendMode(.overlay)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}
