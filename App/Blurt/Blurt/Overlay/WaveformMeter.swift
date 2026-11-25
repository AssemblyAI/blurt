import BlurtEngine
import SwiftUI

/// Resolves the bar-row geometry and hands it to the level-observing leaf.
///
/// The `GeometryReader` lives *above* the view that reads `bridge.level`, which is
/// what makes `MeterBarRow` a per-layout cost instead of a per-tick one: nothing in
/// this body touches the observable, so @Observable never invalidates it and the
/// closure re-runs only on a real resize. Built inside `WaveformBars` (below
/// `WaveformBarsLevel`) it was rebuilt on every ~20 Hz meter tick — an array plus a
/// `sin()` per bar, exactly the per-bar-per-tick work `MeterBarGeometry` precomputes
/// the row to avoid.
struct WaveformMeter: View {
  let bridge: OverlayBridge
  let animated: Bool
  let color: Color

  var body: some View {
    GeometryReader { geo in
      // Bar count, heights, the envelope, and the idle wave are all engine geometry
      // (unit-tested there); this view owns the frame, the color, and the cadence.
      WaveformBarsLevel(
        bridge: bridge,
        layout: MeterBarRow(availableSize: geo.size),
        animated: animated,
        color: color
      )
      .frame(width: geo.size.width, height: geo.size.height)
    }
  }
}
