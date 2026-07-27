import CoreGraphics
import Foundation
import Testing

@testable import BlurtEngine

/// The overlay meter's shape rules. These lived in a SwiftUI `View` body where no
/// test could reach them, so nine tuning constants and the whole bar-height
/// expression were guarded by nothing — the kind of code a "tidy the constants"
/// edit silently breaks.
@Suite("MeterBarGeometry")
struct MeterBarGeometryTests {
  /// The pill is 168×28 (`OverlayWindowController.pillSize`); bars occupy roughly
  /// the right-hand two thirds once the REC tag takes its share.
  private let realisticWidth: CGFloat = 100
  private let realisticHeight: CGFloat = 28

  /// A row laid out for that frame — 15 bars, 22 pt tall — built through the real
  /// derivation rather than by handing the type a count and a height directly. The
  /// size is repeated as literals because a stored property can't read the two
  /// above; `rowDerivesFromFrame` pins that they agree.
  private let row = MeterBarRow(availableSize: CGSize(width: 100, height: 28))

  // MARK: - bar count

  @Test("bar count fills the width at the bar pitch")
  func barCountFillsWidth() {
    // 100 - 2*4 inset = 92 usable; (92 + 3) / (3 + 3) = 15 bars.
    #expect(MeterBarGeometry.barCount(availableWidth: realisticWidth) == 15)
    // Wider frame, more bars — the row is derived, never a fixed count.
    #expect(
      MeterBarGeometry.barCount(availableWidth: 200)
        > MeterBarGeometry.barCount(availableWidth: 100))
  }

  @Test("bar count never drops below the floor, however narrow the frame")
  func barCountFloor() {
    // A one- or two-bar row reads as a glitch, and a zero/negative frame arrives
    // during the first layout pass — all must land on the floor, not crash or
    // return 0 (ForEach(0..<0) would render nothing at all).
    for width in [CGFloat(0), 1, 4, 8, 12, -50] {
      #expect(MeterBarGeometry.barCount(availableWidth: width) == MeterBarGeometry.minBarCount)
    }
  }

  @Test("max bar height insets the frame and stays positive")
  func maxBarHeightInsetsFrame() {
    #expect(
      MeterBarGeometry.maxBarHeight(availableHeight: realisticHeight)
        == realisticHeight - MeterBarGeometry.verticalInset * 2)
    // A degenerate frame must not yield a zero or negative height: a Capsule with
    // a negative frame is a runtime complaint, and 0 makes the meter vanish.
    #expect(MeterBarGeometry.maxBarHeight(availableHeight: 0) == 1)
    #expect(MeterBarGeometry.maxBarHeight(availableHeight: -10) == 1)
  }

  @Test("a row resolves its count and height from the frame it is given")
  func rowDerivesFromFrame() {
    #expect(row.count == MeterBarGeometry.barCount(availableWidth: realisticWidth))
    #expect(row.maxBarHeight == MeterBarGeometry.maxBarHeight(availableHeight: realisticHeight))
    // The degenerate first-layout frame still yields a drawable row.
    let empty = MeterBarRow(availableSize: .zero)
    #expect(empty.count == MeterBarGeometry.minBarCount)
    #expect(empty.maxBarHeight == 1)
  }

  // MARK: - envelope

  @Test("the envelope is symmetric, edge-valued at the ends and 1 at the center")
  func envelopeShape() {
    let count = 15  // odd, so there is a true center bar
    let weights = (0..<count).map { MeterBarGeometry.envelopeWeight(index: $0, count: count) }
    // Tolerances throughout: `sin(.pi * 1)` is not exactly 0 in binary floating
    // point, so the far end lands a few ULPs off `envelopeEdge`.
    #expect(abs((weights.first ?? 0) - MeterBarGeometry.envelopeEdge) < 0.0001)
    #expect(abs((weights.last ?? 0) - MeterBarGeometry.envelopeEdge) < 0.0001)
    #expect(abs(weights[count / 2] - 1) < 0.0001)
    // Mirror image about the center — what makes the row read as one voice hump
    // rather than a bank leaning one way.
    for i in 0..<count {
      #expect(abs(weights[i] - weights[count - 1 - i]) < 0.0001)
    }
    // And never outside [edge, 1], so no bar is ever scaled up past the frame.
    #expect(weights.allSatisfy { $0 >= MeterBarGeometry.envelopeEdge && $0 <= 1 })
  }

  @Test("a single bar gets full weight rather than dividing by zero")
  func envelopeSingleBar() {
    // `count - 1` is the divisor; production can't reach count == 1 (the floor is
    // 3) but the guard is the difference between 1.0 and a NaN height.
    #expect(MeterBarGeometry.envelopeWeight(index: 0, count: 1) == 1)
    #expect(MeterBarGeometry.envelopeWeight(index: 0, count: 0) == 1)
  }

  // MARK: - bar height

  @Test("every bar stays within the floor and the frame, across the level range")
  func barHeightStaysInBounds() {
    let floor = row.maxBarHeight * MeterBarGeometry.minBarHeightFraction
    for level in stride(from: Float(0), through: 1, by: 0.05) {
      for animated in [true, false] {
        for index in 0..<row.count {
          let h = row.height(at: index, level: level, time: 3.7, animated: animated)
          #expect(h >= floor)
          #expect(h <= row.maxBarHeight)
        }
      }
    }
  }

  @Test("a louder level never shortens a bar")
  func barHeightMonotonicInLevel() {
    let center = row.count / 2
    // The center bar carries the most level, so it shows the trend most clearly.
    // Motion off, so the idle wave can't confound the comparison.
    var previous: CGFloat = 0
    for level in stride(from: Float(0), through: 1, by: 0.05) {
      let h = row.height(at: center, level: level, time: 0, animated: false)
      #expect(h >= previous)
      previous = h
    }
    // And the loudest level fills the frame.
    #expect(row.height(at: center, level: 1, time: 0, animated: false) == row.maxBarHeight)
  }

  @Test("with motion off the height depends only on the level, never on time")
  func barHeightIgnoresTimeWhenNotAnimated() {
    // The Reduce Motion contract: no breathing at all. Same level at wildly
    // different clock readings must render identically, or the "animation" is
    // still running for a user who asked for it not to.
    let quiet: Float = 0.02
    let heights = [0, 0.5, 1.0, 37.25, 1_000.5].map { time in
      row.height(at: 4, level: quiet, time: time, animated: false)
    }
    #expect(Set(heights).count == 1)
  }

  @Test("the idle wave moves between words and is gone once the voice comes in")
  func barHeightBreathesOnlyWhenQuiet() {
    // Between words: sampling across one full breath period must produce more than
    // one height, otherwise the "listening" wave is frozen.
    //
    // A *silent* level (exactly 0, which `MicCapture.linearLevel` floors room
    // ambient to) is deliberately not the case under test: `breathDepth` equals
    // `minBarHeightFraction`, so at zero voice the wave never clears the floor and
    // the row is legitimately static. The wave is for the gaps between words,
    // where the level is small but non-zero.
    let quietHeights = stride(from: 0.0, to: MeterBarGeometry.breathPeriod, by: 0.1).map { time in
      row.height(at: 4, level: 0.2, time: time, animated: true)
    }
    #expect(Set(quietHeights).count > 1)

    // Loud: above the fade ceiling the wave contributes nothing, so time stops
    // mattering even with motion on — the level alone drives the bars.
    let loudHeights = stride(from: 0.0, to: MeterBarGeometry.breathPeriod, by: 0.1).map { time in
      row.height(at: 4, level: 0.9, time: time, animated: true)
    }
    #expect(Set(loudHeights).count == 1)
  }

  @Test("the wave is phase-shifted per bar, so a crest travels across the row")
  func idleWavePhaseShiftsPerBar() {
    // What makes the wave *travel* rather than pulse in unison is `wavePhaseStep`:
    // each bar trails its left neighbour. So the gap between two neighbours with
    // motion on must differ from the gap with motion off — the latter is the
    // envelope alone, and any difference is the phase step doing its job.
    func gap(animated: Bool) -> CGFloat {
      func height(_ index: Int) -> CGFloat {
        row.height(at: index, level: 0.2, time: 0.4, animated: animated)
      }
      return height(5) - height(4)
    }
    #expect(abs(gap(animated: true) - gap(animated: false)) > 0.001)
  }

  // MARK: - breathing opacity

  @Test("breathing opacity starts full, dips to the floor, and returns")
  func breathingOpacityCurve() {
    let period = 1.8
    let floor = 0.55
    // Raised cosine: 1 at t=0, the floor at the half period, back to 1 at the end.
    #expect(abs(MeterBarGeometry.breathingOpacity(time: 0, period: period, minOpacity: floor) - 1) < 0.0001)
    #expect(
      abs(
        MeterBarGeometry.breathingOpacity(time: period / 2, period: period, minOpacity: floor)
          - floor) < 0.0001)
    #expect(
      abs(MeterBarGeometry.breathingOpacity(time: period, period: period, minOpacity: floor) - 1)
        < 0.0001)
  }

  @Test("breathing opacity never leaves the floor...1 band")
  func breathingOpacityStaysInBand() {
    // Both call sites' settings: the REC dot (1.2 s / 0.4) and the "Transcribing…"
    // label (1.8 s / 0.55). Anything below the floor would make the 10 pt cyan
    // illegible at the trough; anything above 1 is an invalid opacity.
    for (period, floor) in [(1.2, 0.4), (1.8, 0.55)] {
      for time in stride(from: 0.0, through: 5.0, by: 0.05) {
        let o = MeterBarGeometry.breathingOpacity(time: time, period: period, minOpacity: floor)
        #expect(o >= floor - 0.0001)
        #expect(o <= 1 + 0.0001)
      }
    }
  }
}
