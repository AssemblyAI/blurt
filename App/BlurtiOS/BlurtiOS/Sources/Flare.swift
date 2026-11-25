import BlurtDesign
import SwiftUI

/// The cross flare over the wordmark in a corner: the grille's landing glint
/// at the wordmark's scale — a thin cross in the text colour, its arms past
/// the wordmark, a green and a violet fringe either side of the upright (the
/// violets only ever as light), fading out as it lives.
struct Flare: View {
  let progress: Double

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      let centre = CGPoint(x: size.width / 2, y: size.height / 2)  // literal-ok: the wordmark's centre
      let arm = size.height * DesignTokens.Metrics.keepOpenFlareArm / 2  // literal-ok: half above, half below
      let span = size.width * DesignTokens.Metrics.keepOpenFlareSpan / 2  // literal-ok: half each side
      let line = DesignTokens.Metrics.keepOpenFlareWidth
      let core = DesignTokens.Metrics.keepOpenFlareCore
      let alpha = DesignTokens.Metrics.opacityGlint * (1 - progress)
      let fringe = alpha * 0.4  // literal-ok: the fringe is a fraction of the flare, as the grille's
      ZStack {
        upright(centre, arm: arm, shift: line).stroke(DesignTokens.Brand.violetIris.opacity(fringe), lineWidth: line)
        upright(centre, arm: arm, shift: -line).stroke(DesignTokens.Brand.green400.opacity(fringe), lineWidth: line)
        upright(centre, arm: arm, shift: 0).stroke(BlurtBrand.text.opacity(alpha), lineWidth: line)
        Path { path in
          path.move(to: CGPoint(x: centre.x - span, y: centre.y))
          path.addLine(to: CGPoint(x: centre.x + span, y: centre.y))
        }
        // The horizontal arm sits back.
        .stroke(BlurtBrand.text.opacity(alpha * 0.7), lineWidth: line)  // literal-ok: as the grille's
        Circle()
          .fill(BlurtBrand.text.opacity(alpha))
          .frame(width: core, height: core)
          .position(centre)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func upright(_ centre: CGPoint, arm: CGFloat, shift: CGFloat) -> Path {
    Path { path in
      path.move(to: CGPoint(x: centre.x + shift, y: centre.y - arm))
      path.addLine(to: CGPoint(x: centre.x + shift, y: centre.y + arm))
    }
  }
}
