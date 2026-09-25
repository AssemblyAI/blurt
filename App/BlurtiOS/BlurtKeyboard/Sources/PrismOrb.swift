import BlurtEngine
import SwiftUI

/// The brand's artwork in motion. In the illustration a green beam goes into
/// the prism and a violet, starlit one comes out: green is the input, the
/// voice; violet is the magic, the words. The orb tells that story as it
/// works — leaning green and swelling with the voice while you talk, turning
/// violet while the words are made, finishing violet with a scatter of
/// sparkles when they land. Liquid in its motion (a mesh gradient whose
/// points drift, more with the voice), airy in its look (soft light, low
/// contrast), and matte under film grain, as the artwork is.
///
/// A fill: the caller clips it to a circle or a capsule and puts the ring on
/// top. Under Reduce Motion the fluid holds still and the grain is fixed.
struct PrismOrb: View {
  enum Mood: Equatable {
    /// Blurt is not ready: the brand mix, dimmed by the caller.
    case off
    /// Resting: the brand mix, breathing.
    case idle
    /// The voice going in: green, moving with the level (0…1).
    case listening(level: Float)
    /// The words being made: violet, working.
    case working
    /// The words landed: violet and light, with sparkles.
    case done
  }

  var mood: Mood
  var animated: Bool

  var body: some View {
    TimelineView(.animation(minimumInterval: keyboardAnimationInterval, paused: !animated)) { timeline in
      let time = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
      ZStack {
        Rectangle().fill(mesh(at: time))
        // A soft light from the upper left, so the disc reads as a body, not
        // a flat swatch — airy, not glossy.
        Rectangle().fill(
          RadialGradient(
            colors: [.white.opacity(0.32), .clear], center: UnitPoint(x: 0.3, y: 0.22), startRadius: 0,
            endRadius: 110))
        Grain(seed: animated ? Int(time * 24) : 7).opacity(0.5).blendMode(.overlay)
        if case .done = mood { Sparkles(time: time) }
      }
    }
    .animation(.easeInOut(duration: 0.7), value: mood)
  }

  // MARK: The fluid

  /// A 3 × 3 mesh. The corners stay put; the edge midpoints and the centre
  /// drift on slow sines, further with the voice.
  private func mesh(at time: TimeInterval) -> MeshGradient {
    let level = CGFloat(self.level)
    let sway = 0.10 + 0.16 * level
    func drift(_ base: Float, _ phase: Double, _ speed: Double) -> Float {
      base + Float(sway * sin(time * speed + phase))
    }
    let points: [SIMD2<Float>] = [
      [0, 0], [drift(0.5, 0.0, 0.9), 0], [1, 0],
      [0, drift(0.5, 1.7, 0.7)], [drift(0.5, 3.1, 1.1), drift(0.5, 0.6, 0.8)], [1, drift(0.5, 4.2, 0.6)],
      [0, 1], [drift(0.5, 2.3, 1.0), 1], [1, 1],
    ]
    return MeshGradient(width: 3, height: 3, points: points, colors: colors)
  }

  private var level: Float {
    if case .listening(let level) = mood { return level }
    return 0
  }

  /// Row-major, top to bottom. The brand gradient's own stops
  /// (`BlurtBrand.orbGradient`), dealt differently per mood.
  private var colors: [Color] {
    switch mood {
    case .off, .idle:
      return [
        Palette.white, Palette.lavender, Palette.periwinkle,
        Palette.periwinkle, Palette.greenLight, Palette.violet,
        Palette.green, Palette.greenLight, Palette.violet,
      ]
    case .listening(let level):
      // More green the louder: the beam going in.
      let bright = Color(
        red: 0.40 + 0.3 * Double(level), green: 0.68 + 0.25 * Double(level), blue: 0.51 + 0.1 * Double(level))
      return [
        Palette.lavender, Palette.greenLight, Palette.lavender,
        Palette.greenLight, bright, Palette.greenLight,
        Palette.green, Palette.greenLight, Palette.green,
      ]
    case .working:
      return [
        Palette.lavender, Palette.periwinkle, Palette.lavender,
        Palette.periwinkle, Palette.violet, Palette.periwinkle,
        Palette.violet, Palette.periwinkle, Palette.violet,
      ]
    case .done:
      return [
        Palette.white, Palette.lavender, Palette.white,
        Palette.lavender, Palette.periwinkle, Palette.lavender,
        Palette.violet, Palette.periwinkle, Palette.violet,
      ]
    }
  }

  private enum Palette {
    static let white = Color(red: 0.97, green: 0.96, blue: 1)
    static let lavender = Color(red: 215 / 255, green: 211 / 255, blue: 244 / 255)
    static let periwinkle = Color(red: 176 / 255, green: 167 / 255, blue: 233 / 255)
    static let violet = Color(red: 57 / 255, green: 35 / 255, blue: 199 / 255)
    static let green = BlurtBrand.green
    static let greenLight = BlurtBrand.greenOnDark
  }
}

/// Film grain: a scatter of faint dots, a new scatter each frame so it
/// shimmers the way grain does, drawn from a seed so a frame is reproducible.
private struct Grain: View {
  let seed: Int

  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
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

/// The artwork's stars: a handful of four-point sparkles that twinkle round
/// the orb while the words are landing.
private struct Sparkles: View {
  let time: TimeInterval

  private static let spots: [(x: CGFloat, y: CGFloat, size: CGFloat, phase: Double)] = [
    (0.18, 0.28, 0.16, 0.0), (0.76, 0.2, 0.11, 1.3), (0.82, 0.62, 0.14, 2.6), (0.3, 0.74, 0.1, 3.7),
    (0.58, 0.44, 0.08, 4.9), (0.5, 0.86, 0.12, 1.9),
  ]

  var body: some View {
    GeometryReader { geo in
      ForEach(Array(Self.spots.enumerated()), id: \.offset) { _, spot in
        let pulse = max(0, sin(time * 2.4 + spot.phase))
        Image(systemName: "sparkle")
          .font(.system(size: min(geo.size.width, geo.size.height) * spot.size, weight: .regular))
          .foregroundStyle(.white)
          .opacity(0.35 + 0.65 * pulse)
          .scaleEffect(0.7 + 0.5 * pulse)
          .position(x: geo.size.width * spot.x, y: geo.size.height * spot.y)
      }
    }
    .accessibilityHidden(true)
  }
}
