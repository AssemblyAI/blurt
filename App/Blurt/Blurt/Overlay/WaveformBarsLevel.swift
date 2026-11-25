import BlurtEngine
import SwiftUI

/// The only view that reads `bridge.level`, so @Observable scopes the ~20 Hz
/// meter invalidation to this leaf (and its `WaveformBars` child) instead of the
/// enclosing `OverlayView` — or the `WaveformMeter` above, which is why the
/// geometry it resolves survives a tick. `WaveformBars` stays a pure value view —
/// easy to reason about and drive from a fixed level — with the observation
/// isolated here. See `OverlayView.bridge` for why the level isn't threaded as a
/// value.
struct WaveformBarsLevel: View {
  let bridge: OverlayBridge
  let layout: MeterBarRow
  let animated: Bool
  let color: Color

  var body: some View {
    WaveformBars(level: bridge.level, layout: layout, animated: animated, color: color)
  }
}
