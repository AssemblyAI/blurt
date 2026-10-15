import SwiftUI

/// Film grain: a scatter of faint dots drawn from a seed, so a frame is
/// reproducible — the brand's texture, under the app's pages (`page()`) and on
/// the keyboard's surface (`SurfaceFinish`), still, one seed. Drawn
/// synchronously: a canvas that renders asynchronously never presents inside a
/// keyboard extension.
package struct FilmGrain: View {
  let seed: Int

  package init(seed: Int) { self.seed = seed }

  package var body: some View {
    Canvas { context, size in
      var state = UInt64(truncatingIfNeeded: seed &* 6_364_136_223_846_793_005 &+ 1)
      func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(state >> 40) / CGFloat(1 << 24)
      }
      let count = Int(size.width * size.height / 26)
      for _ in 0..<count {
        let point = CGPoint(x: next() * size.width, y: next() * size.height)
        let shade = next()
        context.fill(
          Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 1, height: 1)),
          with: .color(shade > 0.5 ? .white.opacity(0.18) : .black.opacity(0.22)))
      }
    }
    .accessibilityHidden(true)
  }
}
