import BlurtEngine
import SwiftUI

/// The keyboard's voice row, and the only place voice lives: the orb, which
/// is the mic key — tap to start and stop, hold to talk — growing into the
/// wave while recording. No words: the orb's ring, shape and glow say what is
/// happening, and the haptics confirm it (see `MicKey`).
struct VoiceBar: View {
  var model: KeyboardModel

  static let height: CGFloat = 44

  var body: some View {
    MicKey(model: model, size: 40, expandedWidth: 200)
      .frame(maxWidth: .infinity)
      .frame(height: Self.height)
  }
}

/// The Mac pill's live meter: a row of bars that fills the width it is given
/// and tracks the current level, with the engine's envelope and idle wave
/// (`MeterBarGeometry`, unit-tested there). The keyboard hears the level from
/// the app at ~12 Hz; the wave keeps the row alive between ticks.
struct WaveformMeter: View {
  let level: Float
  let animated: Bool
  let color: Color

  var body: some View {
    GeometryReader { geo in
      let layout = MeterBarRow(availableSize: geo.size)
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
  }

  private func bars(layout: MeterBarRow, time: TimeInterval) -> some View {
    HStack(spacing: MeterBarGeometry.barSpacing) {
      ForEach(0..<layout.count, id: \.self) { index in
        Capsule()
          .fill(color)
          .frame(
            width: MeterBarGeometry.barWidth,
            height: layout.height(at: index, level: level, time: time, animated: animated))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
