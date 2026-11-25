import BlurtEngine
import SwiftUI

/// A row of bars filling the whole pill that track the *current* mic level — no
/// scrolling history. Bars span the full width (count derived from the available
/// width) and grow from the vertical center; a symmetric envelope keeps the
/// middle tallest so the field reads as one voice "blob". When you're between
/// words a gentle wave travels across the bars; the breathing fades out
/// as your voice gets louder. Under Reduce Motion the breathing is dropped and
/// heights simply reflect the level.
struct WaveformBars: View {
  /// Current loudness, 0...1 (MicCapture.linearLevel).
  let level: Float
  /// The precomputed bar row for the current size, resolved once per layout by
  /// `WaveformMeter` — see there for why it isn't built here.
  let layout: MeterBarRow
  /// Whether to run the idle breathing motion (off under Reduce Motion).
  let animated: Bool
  let color: Color

  var body: some View {
    if animated {
      // Continuous clock so the idle breathing is smooth and never depends on a
      // one-shot state toggle; capped at `overlayAnimationInterval`.
      TimelineView(.animation(minimumInterval: overlayAnimationInterval)) { timeline in
        bars(time: timeline.date.timeIntervalSinceReferenceDate)
      }
    } else {
      bars(time: 0)
    }
  }

  private func bars(time: TimeInterval) -> some View {
    HStack(spacing: MeterBarGeometry.barSpacing) {
      ForEach(0..<layout.count, id: \.self) { index in
        Capsule()
          .fill(color)
          .frame(
            width: MeterBarGeometry.barWidth,
            height: layout.height(at: index, level: level, time: time, animated: animated)
          )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
