public import CoreGraphics
public import Foundation

/// Shape of the overlay pill's live level meter — the bar row that tracks the
/// current mic level, plus the brand orb's ring rotation. Pure math, owned in the engine for the same reason as
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
  /// The gap between two bars; public for the same reason as `barWidth`.
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

  /// Symmetric raised-sine window: `envelopeEdge` at the ends rising to 1 at the
  /// center, so the bars form a single voice hump filling the pill width.
  static func envelopeWeight(index: Int, count: Int) -> CGFloat {
    guard count > 1 else {
      return 1
    }
    let position = CGFloat(index) / CGFloat(count - 1)  // 0...1
    return envelopeEdge + (1 - envelopeEdge) * sin(.pi * position)
  }

  /// Angle in degrees of a continuous rotation of `period` seconds per turn —
  /// the brand orb's ring while the pill is waiting on something.
  ///
  /// Wrapped into 0..<360 rather than growing without bound: the value feeds a
  /// `rotationEffect`, and after a long session an ever-increasing angle loses
  /// precision in the `Double` and starts quantising the spin.
  ///
  /// Here beside the meter's idle wave for the same reason: it's the pill's
  /// motion expressed as a pure function of the clock, so it's testable without
  /// a view and can't drift into a second, subtly different curve.
  public static func rotationDegrees(time: TimeInterval, period: Double) -> Double {
    guard period > 0 else {
      return 0
    }
    let turns = time / period
    return (turns - turns.rounded(.down)) * 360
  }
}
