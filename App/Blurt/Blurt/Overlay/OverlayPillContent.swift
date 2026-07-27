import BlurtEngine
import SwiftUI

enum OverlayBrandPalette {
  static let cyan = Color(red: 0.20, green: 0.88, blue: 0.96)
  static let magenta = Color(red: 0.98, green: 0.12, blue: 0.73)
}

/// The shared type, tracking, and cyan color for the overlay's status-line
/// text ("Transcribing…", "Pasted", and "Copied") so they can't drift out of
/// sync.
struct StatusLineText: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .tracking(0.8)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .foregroundStyle(OverlayBrandPalette.cyan)
  }
}

/// Redraw cap for the pill's continuous animations — the REC dot's pulse, the
/// "Transcribing…" breath, and the waveform's idle wave.
///
/// Read from the engine rather than restated: the cap exists *because* of the mic
/// meter's cadence (the level feed and these slow sines can't show anything
/// faster, so rendering at the display's full refresh rate — up to 120 Hz on
/// ProMotion — would only burn energy), so it tracks that one number instead of
/// duplicating it behind a comment that could go stale.
private let overlayAnimationInterval = MicCapture.meterIntervalSeconds

extension View {
  /// Raised-cosine opacity breathing over `period`: 1 → `minOpacity` → 1, so the
  /// view eases through the dim point instead of bouncing off it. Shared by the
  /// REC dot and the "Transcribing…" label so the pill's two heartbeats stay one
  /// curve. With `animated` false (Reduce Motion) the view renders untouched.
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

/// The "Transcribing…" status line with a slow breathing pulse — the processing
/// counterpart of the recording bars' idle shimmer, so the pill keeps visibly
/// working while the app waits on the Sync API and pastes the result. Driven by
/// the same continuous-clock `TimelineView` pattern as `WaveformBars` (never a
/// one-shot state toggle). Under Reduce Motion the label holds steady at full
/// opacity — exactly the pre-animation rendering.
struct TranscribingLabel: View {
  /// Whether to run the breathing motion (off under Reduce Motion).
  let animated: Bool

  // One breath every ~1.8 s, dimming to ~55% and back: slow and shallow enough
  // to read as a calm heartbeat rather than an alert blink. The floor keeps the
  // 10 pt cyan legible against the dark tint at the trough, and limits the
  // brightness pop if the cross-fade to "Pasted" (rendered at full opacity)
  // starts mid-breath.
  private let breathPeriod: Double = 1.8
  private let minOpacity: Double = 0.55

  var body: some View {
    label.pulsingOpacity(period: breathPeriod, minOpacity: minOpacity, animated: animated)
  }

  // Shared with the "Pasted" notice (OverlayView's `.pasted` case) so the
  // processing → pasted hand-off reads as one status line.
  private var label: some View {
    StatusLineText("Transcribing…")
  }
}

/// The "● REC" recording tag: a pulsing magenta dot + "REC" caption, sitting to
/// the left of the waveform — the native echo of the site demo's magenta pixel
/// tag. Magenta (the brand --hot) stands in for the conventional red record dot;
/// its slow pulse (see `dot`) carries the live-capture affordance while the cyan
/// bars carry the level.
struct RecordingTag: View {
  /// Whether to pulse the dot (off under Reduce Motion).
  let animated: Bool

  // One pulse every ~1.2 s, dimming to 40% and back: the universal "recording,
  // right now" heartbeat. Since magenta stands in for the conventional red dot,
  // the pulse — not the hue — carries the live-capture cue. Driven by the same
  // continuous-clock TimelineView as the waveform and TranscribingLabel (never a
  // one-shot repeatForever toggle).
  private let pulsePeriod: Double = 1.2
  private let minOpacity: Double = 0.4

  var body: some View {
    HStack(spacing: 4) {
      dot
      Text("REC")
        .font(.system(size: 9, weight: .semibold))
        .tracking(1.2)
        .foregroundStyle(OverlayBrandPalette.magenta)
    }
    .fixedSize()
  }

  /// The magenta record dot, breathing while recording.
  private var dot: some View {
    circle.pulsingOpacity(period: pulsePeriod, minOpacity: minOpacity, animated: animated)
  }

  private var circle: some View {
    Circle()
      .fill(OverlayBrandPalette.magenta)
      .frame(width: 5, height: 5)
  }
}

/// The only view that reads `bridge.level`, so @Observable scopes the ~20 Hz
/// meter invalidation to this leaf (and its `WaveformBars` child) instead of the
/// enclosing `OverlayView`. `WaveformBars` stays a pure value view — easy to
/// reason about and drive from a fixed level — with the observation isolated
/// here. See `OverlayView.bridge` for why the level isn't threaded as a value.
struct WaveformBarsLevel: View {
  let bridge: OverlayBridge
  let animated: Bool
  let color: Color

  var body: some View {
    WaveformBars(level: bridge.level, animated: animated, color: color)
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
  /// Whether to run the idle breathing motion (off under Reduce Motion).
  let animated: Bool
  let color: Color

  var body: some View {
    GeometryReader { geo in
      // Bar count, heights, the envelope, and the idle wave are all engine
      // geometry (unit-tested there); this view owns the frame, the color, and the
      // redraw cadence. Resolved once per layout, then shared by every bar.
      let layout = MeterBarRow(availableSize: geo.size)
      Group {
        if animated {
          // Continuous clock so the idle breathing is smooth and never depends
          // on a one-shot state toggle; capped at `overlayAnimationInterval`.
          TimelineView(.animation(minimumInterval: overlayAnimationInterval)) { timeline in
            bars(layout, time: timeline.date.timeIntervalSinceReferenceDate)
          }
        } else {
          bars(layout, time: 0)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
  }

  private func bars(_ layout: MeterBarRow, time: TimeInterval) -> some View {
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
