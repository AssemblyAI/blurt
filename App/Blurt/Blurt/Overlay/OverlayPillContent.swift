import BlurtEngine
import SwiftUI

/// The shared type, tracking, and color for the overlay's status-line text
/// ("Transcribing", "Pasted", "Copied", "Error") so they can't drift out of
/// sync.
///
/// Set in tracked uppercase, as the design draws it — the caps and the letter
/// spacing are what make a bare word read as a status readout rather than as a
/// sentence that lost its ending. The call sites pass ordinary capitalisation
/// and `textCase` does the shouting, so the strings stay readable in source and
/// the engine's accessibility labels (which speak the same states) aren't
/// dragged into all-caps.
struct StatusLineText: View {
  let text: String
  /// The text color — brand green for every state but `.error`, which the
  /// design gives its own orange rather than a red pill body.
  var color: Color = BlurtBrand.greenOnDark

  init(_ text: String, color: Color = BlurtBrand.greenOnDark) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(.system(size: 9, weight: .semibold))
      .textCase(.uppercase)
      .tracking(0.9)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .foregroundStyle(color)
  }
}

/// Redraw cap for the pill's continuous animations — the brand orb's ring sweep
/// (`BrandOrb`, which is why this isn't file-private) and the waveform's idle
/// wave.
///
/// Read from the engine rather than restated: the cap exists *because* of the mic
/// meter's cadence (the level feed and these slow sines can't show anything
/// faster, so rendering at the display's full refresh rate — up to 120 Hz on
/// ProMotion — would only burn energy), so it tracks that one number instead of
/// duplicating it behind a comment that could go stale.
let overlayAnimationInterval = MicCapture.meterIntervalSeconds

extension View {
  /// Raised-cosine opacity breathing over `period`: 1 → `minOpacity` → 1, so the
  /// view eases through the dim point instead of bouncing off it. With
  /// `animated` false (Reduce Motion) the view renders untouched.
  ///
  /// Lives here rather than beside its one remaining caller (`ReadyView`'s
  /// Listening glyph) because it's the overlay's breathing curve — the pill's
  /// own uses moved to the orb's ring sweep, and the main window borrows the
  /// cadence deliberately so the two windows' motion matches.
  @ViewBuilder
  func pulsingOpacity(period: Double, minOpacity: Double, animated: Bool) -> some View {
    if animated {
      TimelineView(.animation(minimumInterval: overlayAnimationInterval)) { timeline in
        self.opacity(
          MeterBarGeometry.breathingOpacity(
            time: timeline.date.timeIntervalSinceReferenceDate,
            period: period, minOpacity: minOpacity))
      }
    } else {
      self
    }
  }
}

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
        bridge: bridge, layout: MeterBarRow(availableSize: geo.size),
        animated: animated, color: color
      )
      .frame(width: geo.size.width, height: geo.size.height)
    }
  }
}

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

/// A row of bars filling the whole pill that track the *current* mic level — no
/// scrolling history. Bars span the full width (count derived from the available
/// width) and grow from the vertical center; a symmetric envelope keeps the
/// middle tallest so the field reads as one voice "blob". When you're between
/// words a gentle wave travels across the bars; the breathing fades out
/// as your voice gets louder. Under Reduce Motion the breathing is dropped and
/// heights simply reflect the level.
private struct WaveformBars: View {
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
            height: layout.height(at: index, level: level, time: time, animated: animated))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
