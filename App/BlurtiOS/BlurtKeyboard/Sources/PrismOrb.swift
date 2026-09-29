import SwiftUI

/// The brand's artwork in motion. In the illustration a green beam goes into
/// the prism and a violet, starlit one comes out: green is the input, the
/// voice; violet is the magic, the words. The orb lives green — calm at rest,
/// swelling with the voice while you talk — and the moment the words land in
/// the field a violet drop falls into it: a glittering pulse that blooms from
/// the centre with the haptic, then flows back out into the green. Liquid in
/// its motion (a mesh gradient whose points drift), airy in its look (soft
/// light, low contrast), matte under film grain, as the artwork is.
///
/// A fill: the caller clips it to a circle or a capsule and puts the ring on
/// top. Under Reduce Motion the fluid holds still and the drop simply fades.
struct PrismOrb: View {
  enum Mood: Equatable {
    /// Blurt is not ready: the calm green, dimmed by the caller.
    case off
    /// Resting: the calm green, breathing.
    case idle
    /// The voice going in: greener and moving with the level (0…1).
    case listening(level: Float)
    /// The words being made: the calm green, working.
    case working
  }

  var mood: Mood
  /// When the words landed — the drop falls then and is gone 2.4 s later.
  var landedAt: Date?
  var animated: Bool

  /// The drop's life: up in 0.5 s, held to 0.9 s, gone by 2.4 s — an event,
  /// but a soft one.
  static let dropDuration: TimeInterval = DesignTokens.Motion.drop
  static let dropRise: TimeInterval = DesignTokens.Motion.dropRise
  static let dropHold: TimeInterval = DesignTokens.Motion.dropHold

  var body: some View {
    TimelineView(.animation(minimumInterval: keyboardAnimationInterval, paused: !animated)) { timeline in
      let time = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
      let elapsed = landedAt.map { timeline.date.timeIntervalSince($0) } ?? .infinity
      let drop = Self.dropAmount(at: elapsed)
      ZStack {
        Rectangle().fill(mesh(at: time, drop: drop))
        // A soft light from the upper left, so the disc reads as a body, not
        // a flat swatch — airy, not glossy.
        GeometryReader { geo in
          Rectangle().fill(
            RadialGradient(
              colors: [.white.opacity(DesignTokens.Metrics.opacityOrbLight), .clear],
              center: UnitPoint(x: DesignTokens.Metrics.orbLightX, y: DesignTokens.Metrics.orbLightY), startRadius: 0,
              endRadius: min(geo.size.width, geo.size.height) * DesignTokens.Metrics.orbLightReach))
        }
        if drop > 0 {
          Drop(amount: drop, elapsed: elapsed)
          Sparkles(elapsed: elapsed)  // invariant-ok: the orb's star glyphs, not the Sparkle updater
        }
        BlurtiOSGrain(seed: animated ? Int(time * 24) : 7).opacity(DesignTokens.Metrics.opacityGrain).blendMode(
          .overlay)
      }
    }
    .animation(.easeInOut(duration: DesignTokens.Motion.mood), value: mood)
  }

  /// How much violet is in the orb `elapsed` seconds after the words landed:
  /// a quick bloom, a moment held, a slow flow back to green.
  static func dropAmount(at elapsed: TimeInterval) -> Double {
    guard elapsed >= 0, elapsed < dropDuration else { return 0 }
    func smooth(_ x: Double) -> Double {
      let t = min(max(x, 0), 1)
      return t * t * (3 - 2 * t)
    }
    if elapsed < dropRise { return smooth(elapsed / dropRise) }
    if elapsed < dropHold { return 1 }
    return 1 - smooth((elapsed - dropHold) / (dropDuration - dropHold))
  }

  // MARK: The fluid

  /// A 3 × 3 mesh. The corners stay put; the edge midpoints and the centre
  /// drift on slow sines, further with the voice.
  private func mesh(at time: TimeInterval, drop: Double) -> MeshGradient {
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
    // The drop soaks the centre first and the corners least.
    let soak: [Double] = [0.45, 0.75, 0.45, 0.75, 1, 0.75, 0.45, 0.75, 0.45]
    let colors = zip(green, soak).map { base, weight in
      base.mix(with: Palette.violet, by: drop * weight)
    }
    return MeshGradient(width: 3, height: 3, points: points, colors: colors)
  }

  private var level: Float {
    if case .listening(let level) = mood { return level }
    return 0
  }

  /// Row-major, top to bottom: the green the orb lives in, with the brand's
  /// pale lavender as the light on top so it stays airy.
  private var green: [Color] {
    switch mood {
    case .off, .idle, .working:
      return [
        Palette.lavender, Palette.mist, Palette.lavender,
        Palette.greenLight, Palette.greenLight, Palette.greenLight,
        Palette.green, Palette.greenLight, Palette.green,
      ]
    case .listening(let level):
      // Greener and brighter the louder: the beam going in.
      let bright = Palette.greenLight.mix(with: Palette.mist, by: 0.25 + 0.45 * Double(level))
      return [
        Palette.mist, bright, Palette.mist,
        Palette.greenLight, bright, Palette.greenLight,
        Palette.green, Palette.greenLight, Palette.green,
      ]
    }
  }

  /// The orb's colours, by the part they play; the values are the brand's.
  private enum Palette {
    static let mist = DesignTokens.Brand.greenMist
    static let lavender = DesignTokens.Brand.violetLavender
    static let periwinkle = DesignTokens.Brand.violetPeriwinkle
    static let violet = DesignTokens.Brand.cobolt
    static let green = DesignTokens.Brand.green700
    static let greenLight = DesignTokens.Brand.green400
  }

  /// The drop itself: a violet bloom that grows from the centre and thins as
  /// it spreads, so the colour reads as poured in rather than switched.
  private struct Drop: View {
    let amount: Double
    let elapsed: TimeInterval

    var body: some View {
      let spread = min(1, elapsed / DesignTokens.Motion.dropSpread)
      Circle()
        .fill(
          RadialGradient(
            colors: [Palette.violet.opacity(0.9), Palette.periwinkle.opacity(0.55), .clear],
            center: .center, startRadius: 0, endRadius: 90)
        )
        .scaleEffect(0.15 + 1.6 * spread)
        .opacity(amount * (1 - 0.5 * spread))
        .blendMode(.plusLighter)
    }
  }
}

/// Film grain: a scatter of faint dots, a new scatter each frame so it
/// shimmers the way grain does, drawn from a seed so a frame is reproducible.
/// The orb's, and — still, one seed — the keyboard surface's (`SurfaceFinish`).
struct BlurtiOSGrain: View {
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

/// The artwork's stars: six four-point sparkles that burst once with the
/// drop — each a beat after the last — and are gone with it.
private struct Sparkles: View {  // invariant-ok: the orb's star glyphs, not the Sparkle updater
  let elapsed: TimeInterval

  private struct Spot {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let delay: Double
  }

  private static let spots: [Spot] = [
    Spot(x: 0.5, y: 0.5, size: 0.14, delay: 0.08), Spot(x: 0.24, y: 0.3, size: 0.16, delay: 0.24),
    Spot(x: 0.76, y: 0.22, size: 0.11, delay: 0.4), Spot(x: 0.8, y: 0.64, size: 0.14, delay: 0.5),
    Spot(x: 0.3, y: 0.74, size: 0.1, delay: 0.64), Spot(x: 0.56, y: 0.84, size: 0.12, delay: 0.77),
  ]

  var body: some View {
    GeometryReader { geo in
      ForEach(Array(Self.spots.enumerated()), id: \.offset) { _, spot in
        let life = (elapsed - spot.delay) / 1.3
        let up = min(max(life, 0), 1)
        let shine = up < 0.3 ? up / 0.3 : max(0, 1 - (up - 0.3) / 0.7)
        Image(systemName: "sparkle")
          .font(.system(size: min(geo.size.width, geo.size.height) * spot.size, weight: .regular))
          .foregroundStyle(.white)
          .opacity(shine)
          .scaleEffect(0.4 + 0.9 * shine)
          .position(x: geo.size.width * spot.x, y: geo.size.height * spot.y)
      }
    }
    .accessibilityHidden(true)
  }
}
