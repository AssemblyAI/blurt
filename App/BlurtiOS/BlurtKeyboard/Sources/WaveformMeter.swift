import BlurtEngine
import SwiftUI

/// The Mac pill's live meter: a row of bars that fills the width it is given
/// and tracks the current level, with the engine's envelope and idle wave
/// (`MeterBarGeometry`, unit-tested there). The keyboard hears the level from
/// the app at ~12 Hz; the wave keeps the row alive between ticks. The pitch
/// is the Mac's unless the caller sets its own: the keyboard's wave is thin —
/// `slimBar` wide, `slimGap` apart — and dense, a fine signal rather than a
/// bank of bars.
struct WaveformMeter: View {
  let level: Float
  let animated: Bool
  let color: Color
  var barWidth: CGFloat = MeterBarGeometry.barWidth
  var barSpacing: CGFloat = MeterBarGeometry.barSpacing

  /// The keyboard's pitch: 2 pt bars, 2 pt apart.
  static let slimBar = DesignTokens.Metrics.waveBar
  static let slimGap = DesignTokens.Metrics.waveGap

  var body: some View {
    GeometryReader { geo in
      let count = Int((geo.size.width + barSpacing) / (barWidth + barSpacing))
      let layout = MeterBarRow(count: count, availableHeight: geo.size.height)
      Group {
        if animated {
          TimelineView(.animation(minimumInterval: keyboardAnimationInterval)) { timeline in
            bars(layout: layout, time: timeline.date.timeIntervalSinceReferenceDate)
          }
        } else {
          bars(layout: layout, time: 0)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .accessibilityHidden(true)
  }

  private func bars(layout: MeterBarRow, time: TimeInterval) -> some View {
    HStack(spacing: barSpacing) {
      ForEach(0..<layout.count, id: \.self) { index in
        Capsule()
          .fill(color)
          .frame(width: barWidth, height: layout.height(at: index, level: level, time: time, animated: animated))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
