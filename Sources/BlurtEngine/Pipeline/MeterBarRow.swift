import CoreGraphics
public import Foundation

/// One laid-out row of meter bars: how many fit the frame and how tall each may
/// be, resolved once per render so the count used to lay the row out and the count
/// used to shape it can't disagree.
///
/// A value rather than more `MeterBarGeometry` statics because `count` and
/// `maxBarHeight` are facts about the *row*, and threading them through every
/// per-bar call made the height function take six arguments — the row itself is
/// what they belong to.
public struct MeterBarRow: Sendable, Equatable {
  /// Bars that fit the width, never below `MeterBarGeometry.minBarCount`.
  public let count: Int
  /// The tallest a bar in this row may be.
  public let maxBarHeight: CGFloat

  /// `MeterBarGeometry.envelopeWeight` per bar. Resolved here with `count` because
  /// it is a fact about the row's layout, not about a frame: recomputed inside
  /// `height(at:)` it was a `sin()` per bar per meter tick (~16 bars at 20 Hz)
  /// re-deriving values that only change when the pill is resized.
  private let weights: [CGFloat]

  /// Resolves the row for the frame the meter has been given.
  public init(availableSize: CGSize) {
    self.init(
      count: MeterBarGeometry.barCount(availableWidth: availableSize.width),
      availableHeight: availableSize.height
    )
  }

  // periphery:ignore - public for the iOS keyboard (App/BlurtiOS), which the Mac scan doesn't index.
  /// Resolves the row for a caller that lays out its own pitch — the iPhone
  /// keyboard's thin wave draws 2 pt bars 2 pt apart — with `count` bars in a
  /// frame `availableHeight` tall. Never fewer than `minBarCount` bars.
  public init(count: Int, availableHeight: CGFloat) {
    let barCount = max(MeterBarGeometry.minBarCount, count)
    self.count = barCount
    self.maxBarHeight = MeterBarGeometry.maxBarHeight(availableHeight: availableHeight)
    self.weights = (0..<barCount).map { index in
      MeterBarGeometry.envelopeWeight(index: index, count: barCount)
    }
  }

  /// Height of the bar at `index` for the current `level`.
  ///
  /// `level` is the `0...1` scale `MicCaptureProtocol.levels` documents; the range
  /// is guaranteed once by `OverlayBridge.pushLevel`, the single seam where a
  /// capture implementation crosses into the view layer, so it isn't re-checked
  /// here. `time` advances the idle wave and is ignored unless `animated` — pass
  /// `animated: false` to honor Reduce Motion, which drops the wave entirely.
  public func height(at index: Int, level: Float, time: TimeInterval, animated: Bool) -> CGFloat {
    // Out-of-range indices can't shape a bar that isn't in the row; fall back to the
    // unweighted 1 rather than trapping, matching `envelopeWeight`'s count <= 1 arm.
    let weight = weights.indices.contains(index) ? weights[index] : 1
    // Voice-driven height: the current level, gamma-shaped, scaled by this bar's
    // envelope weight so the middle leads.
    let voice = pow(CGFloat(level), MeterBarGeometry.levelGamma) * weight
    var breath: CGFloat = 0
    // Full breathing when quiet, fading to none once the voice is moderate. Once
    // it's faded out the per-bar sine would multiply to ~0, so skip it entirely on
    // the louder frames rather than computing-then-zeroing.
    let idleStrength = animated ? max(0, 1 - voice / MeterBarGeometry.breathFadeCeiling) : 0
    if idleStrength > 0 {
      // A gentle wave travelling left→right across the row while you're quiet, so
      // "listening" reads as alive and directional rather than a frozen line. The
      // phase advances with time and steps back per bar, sending a soft crest
      // sweeping across; it fades out (`idleStrength`) as your voice comes in.
      let phase =
        time / MeterBarGeometry.breathPeriod * 2 * .pi
        - Double(index) * MeterBarGeometry.wavePhaseStep
      let osc = (sin(phase) + 1) / 2  // 0...1
      breath = MeterBarGeometry.breathDepth * weight * CGFloat(osc) * idleStrength
    }
    let fraction = max(MeterBarGeometry.minBarHeightFraction, voice + breath)
    return maxBarHeight * min(1, fraction)
  }
}
