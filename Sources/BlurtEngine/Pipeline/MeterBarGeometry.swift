import CoreGraphics
import Foundation

/// Shape of the overlay pill's live level meter — the bar row that tracks the
/// current mic level, plus the breathing curve the REC dot and "Transcribing…"
/// label share. Pure math, owned in the engine for the same reason as
/// `OverlayPlacement`: the rules are worth pinning, and a SwiftUI `View` body is
/// not somewhere a test can reach them.
///
/// The caller supplies the frame it has and the current level; everything about
/// *how many* bars, *how tall* each one is, and how the idle wave travels lives
/// here. Colors, `Capsule`s, and `TimelineView` cadence stay in the view.
public enum MeterBarGeometry {
  /// Width of a single bar, and the gap between two. Public because the view lays
  /// the row out with them (`HStack(spacing:)` and each bar's frame), so `barCount`
  /// below and the actual layout can't disagree about the pitch.
  public static let barWidth: CGFloat = 3
  public static let barSpacing: CGFloat = 3

  /// Insets taken off the frame before bars are placed. The REC tag and the
  /// enclosing HStack padding already hold the row clear of the capsule's rounded
  /// ends, so the bar field only needs a hair of its own.
  static let horizontalInset: CGFloat = 4
  static let verticalInset: CGFloat = 3

  /// Floor on every bar, so a silent pill reads as a row of dots rather than
  /// nothing at all.
  static let minBarHeightFraction: CGFloat = 0.12

  /// Compresses the `0...1` level into bar height. Lowish so normal speech already
  /// fills much of the pill height; raise toward 2 for shorter bars.
  static let levelGamma: CGFloat = 1.3

  /// Height fraction at the far ends of the symmetric envelope (the center is 1),
  /// which is what makes the row read as one voice "blob" rather than a flat bank.
  static let envelopeEdge: CGFloat = 0.45

  /// How far a bar travels while idle-breathing.
  static let breathDepth: CGFloat = 0.12

  /// Idle wave: one full sweep every `breathPeriod`, each bar trailing its left
  /// neighbour by `wavePhaseStep` radians, so a soft crest travels left→right.
  static let breathPeriod: Double = 2.0
  static let wavePhaseStep: Double = 0.45

  /// Voice level at which the idle breathing has faded out completely. Above it
  /// the wave contributes nothing, so `barHeight` skips computing it.
  static let breathFadeCeiling: CGFloat = 0.25

  /// Never fewer than this many bars, however narrow the frame — a two-bar row
  /// reads as a glitch rather than a meter.
  static let minBarCount = 3

  /// How many bars fit `availableWidth`. Derived rather than fixed so the row
  /// fills whatever width the pill gives it.
  public static func barCount(availableWidth: CGFloat) -> Int {
    let usable = max(1, availableWidth - horizontalInset * 2)
    return max(minBarCount, Int((usable + barSpacing) / (barWidth + barSpacing)))
  }

  /// The tallest a bar may be inside `availableHeight`.
  public static func maxBarHeight(availableHeight: CGFloat) -> CGFloat {
    max(1, availableHeight - verticalInset * 2)
  }

  /// Height of the bar at `index` for the current `level`.
  ///
  /// `level` is the `0...1` scale `MicCaptureProtocol.levels` documents; the range
  /// is guaranteed once by `OverlayBridge.pushLevel`, the single seam where a
  /// capture implementation crosses into the view layer, so it isn't re-checked
  /// here. `time` advances the idle wave and is ignored unless `animated`; pass 0
  /// when motion is off (Reduce Motion), which the `animated` flag also enforces.
  public static func barHeight(
    index: Int,
    count: Int,
    maxBarHeight: CGFloat,
    level: Float,
    time: TimeInterval,
    animated: Bool
  ) -> CGFloat {
    let weight = envelopeWeight(index: index, count: count)
    // Voice-driven height: the current level, gamma-shaped, scaled by this bar's
    // envelope weight so the middle leads.
    let voice = pow(CGFloat(level), levelGamma) * weight
    var breath: CGFloat = 0
    // Full breathing when quiet, fading to none once the voice is moderate. Once
    // it's faded out the per-bar sine would multiply to ~0, so skip it entirely on
    // the louder frames rather than computing-then-zeroing.
    let idleStrength = animated ? max(0, 1 - voice / breathFadeCeiling) : 0
    if idleStrength > 0 {
      // A gentle wave travelling left→right across the row while you're quiet, so
      // "listening" reads as alive and directional rather than a frozen line. The
      // phase advances with time and steps back per bar, sending a soft crest
      // sweeping across; it fades out (`idleStrength`) as your voice comes in.
      let phase = time / breathPeriod * 2 * .pi - Double(index) * wavePhaseStep
      let osc = (sin(phase) + 1) / 2  // 0...1
      breath = breathDepth * weight * CGFloat(osc) * idleStrength
    }
    let fraction = max(minBarHeightFraction, voice + breath)
    return maxBarHeight * min(1, fraction)
  }

  /// Symmetric raised-sine window: `envelopeEdge` at the ends rising to 1 at the
  /// center, so the bars form a single voice hump filling the pill width.
  static func envelopeWeight(index: Int, count: Int) -> CGFloat {
    guard count > 1 else { return 1 }
    let t = CGFloat(index) / CGFloat(count - 1)  // 0...1
    return envelopeEdge + (1 - envelopeEdge) * sin(.pi * t)
  }

  /// Raised-cosine opacity breathing over `period`: 1 → `minOpacity` → 1, so a view
  /// eases through the dim point instead of bouncing off it.
  ///
  /// Shared by the REC dot and the "Transcribing…" label so the pill's two
  /// heartbeats are literally one curve rather than two that look alike.
  public static func breathingOpacity(time: TimeInterval, period: Double, minOpacity: Double)
    -> Double
  {
    let osc = (cos(time / period * 2 * .pi) + 1) / 2  // 0...1
    return minOpacity + (1 - minOpacity) * osc
  }
}
