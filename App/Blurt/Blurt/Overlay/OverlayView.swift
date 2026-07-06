import BlurtEngine
import SwiftUI

private enum OverlayBrandPalette {
  static let cyan = Color(red: 0.20, green: 0.88, blue: 0.96)
  static let magenta = Color(red: 0.98, green: 0.12, blue: 0.73)
}

struct OverlayView: View {
  let state: OverlayUIState
  let level: Float

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // The pill is only on screen while a dictation is happening, always at its full
  // size — it fades in on key-down and out at idle (OverlayWindowController), so
  // there's no collapsed/hover resting state. The size is the panel's pill size
  // (the panel is sized off it plus the shadow margin) so the capsule fills the
  // window exactly — single source of truth lives on OverlayWindowController.
  private var pillWidth: CGFloat { OverlayWindowController.pillSize.width }
  private var pillHeight: CGFloat { OverlayWindowController.pillSize.height }

  // A dark tint infused into the Liquid Glass capsule. `.regular` glass passes
  // more of the backdrop through than the old frosted-material-plus-fill stack,
  // so these run deeper than the material-era values (0.5–0.58) to keep the
  // white bars and 10 pt status text legible over a bright desktop — tune
  // on-device if the pill reads too heavy over dark wallpapers.
  private var tintColor: Color {
    switch state {
    case .error:
      return .red.opacity(0.6)
    case .recording, .pasted, .noTarget:
      // "Pasted"/"Copied" share recording's cyan-tinted frame: same brand --ice
      // language, reading as an informational notice rather than the red error flash.
      return Color(red: 0.08, green: 0.2, blue: 0.24).opacity(0.68)
    case .processing:
      return Color(red: 0.18, green: 0.12, blue: 0.24).opacity(0.7)
    case .idle:
      return .black.opacity(0.6)
    }
  }

  var body: some View {
    content
      .frame(width: pillWidth, height: pillHeight)
      // Real Liquid Glass, not the pre-Tahoe imitation stack (frosted material +
      // tint overlay + stroke): the system draws the refractive edge highlights,
      // so the per-state story is carried by the tint alone. Deliberately not
      // `.interactive()` — the pill is a passive status surface, and interactive
      // glass hit-testing could swallow the mouse-down that starts the panel's
      // `isMovableByWindowBackground` drag, the only way to reposition the pill.
      // No `GlassEffectContainer`/`glassEffectID` either: there is exactly one
      // glass element and its capsule never changes shape or presence, so the
      // morph machinery would be inert scaffolding.
      .glassEffect(.regular.tint(tintColor), in: .capsule)
      // Flatten the glass into one layer before shadowing so the drop shadow
      // takes the capsule's rounded alpha, not the rectangular layer bounds
      // (which renders as a boxy halo, most visible on a white backdrop). The
      // explicit shadow keeps the dark pill separated from light content —
      // whatever ambient shadow the system gives glass is subtle and outside
      // our control. Radius + offset stay within
      // OverlayWindowController.shadowMargin (16) so the soft falloff completes
      // before the panel edge rather than clipping.
      .compositingGroup()
      .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: state)
      .contentShape(Rectangle())
      // Transparent margin so the shadow has room to render without being
      // clipped by the panel's contentRect (most visible at the rounded ends).
      // Matches OverlayWindowController.shadowMargin.
      .padding(OverlayWindowController.shadowMargin)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(state.accessibilityLabel)
      .accessibilityIdentifier("overlay.pill")
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .idle:
      // The pill is hidden at idle; this branch only renders during the brief
      // fade-out, where the capsule is on its way off screen.
      EmptyView()
    case .recording:
      // "● REC" tag beside the live waveform, mirroring the site demo's recording
      // pill (magenta tag + bars). The bars fill the width left of the tag.
      HStack(spacing: 8) {
        RecordingTag()
        WaveformBars(level: level, animated: !reduceMotion, color: OverlayBrandPalette.cyan)
      }
      .padding(.horizontal, 12)
      .transition(.opacity)
    case .processing:
      // Matches the site demo's "Transcribing…" label (the demo cross-fades REC →
      // Transcribing); cyan echoes the demo's --ice. Cross-fades like the bars.
      // The label breathes (slow opacity pulse) so the wait for the Sync API +
      // paste reads as active work rather than a frozen pill.
      TranscribingLabel(animated: !reduceMotion)
        .transition(.opacity)
    case .error(let message):
      // "Try again" tells the user what to do; the full failure reason is too
      // long for the pill, so expose it on hover. The VoiceOver announcement
      // (OverlayWindowController) speaks the same message for non-sighted users.
      noticePill(symbol: "arrow.clockwise", tint: .white, label: "Try again", help: message)
    case .pasted:
      // Quiet, informational notice confirming the transcript was typed into the
      // focused field. Styled exactly like "Transcribing…" (same type, tracking,
      // and cyan --ice) so the processing → pasted hand-off reads as one
      // continuous status line rather than a new kind of alert. No glyph — the
      // word alone carries it. Hover still exposes the full announcement text.
      StatusLineText("Pasted")
        .transition(.opacity)
        .help(state.accessibilityLabel)
    case .noTarget:
      // Quiet, informational notice: there was no text field to type into, so the
      // transcript went to the clipboard. Cyan (the brand --ice, same as
      // "Transcribing…") so it reads as info, not the red error flash.
      noticePill(
        symbol: "doc.on.clipboard", tint: OverlayBrandPalette.cyan, label: "Copied",
        help: state.accessibilityLabel)
    }
  }

  /// A brief notice pill — an SF Symbol + short label — for the transient
  /// `.error` / `.noTarget` states, which differ only in glyph, color, label,
  /// and hover text. `tint` colors both the glyph and the label. `help` is the
  /// hover tooltip — pass `state.accessibilityLabel` so it stays the same
  /// string the window controller announces to VoiceOver (the wording lives in
  /// one place, `OverlayUIState`).
  private func noticePill(
    symbol: String, tint: Color, label: String, help: String
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.callout.weight(.semibold))
        .foregroundStyle(tint)
      Text(label)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .foregroundStyle(tint)
    }
    .padding(.horizontal, 4)
    .transition(.opacity)
    .help(help)
  }
}

/// The shared type, tracking, and cyan color for the overlay's status-line
/// text ("Transcribing…" and "Pasted") so the two can't drift out of sync.
private struct StatusLineText: View {
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

/// The "Transcribing…" status line with a slow breathing pulse — the processing
/// counterpart of the recording bars' idle shimmer, so the pill keeps visibly
/// working while the app waits on the Sync API and pastes the result. Driven by
/// the same continuous-clock `TimelineView` pattern as `WaveformBars` (never a
/// one-shot state toggle). Under Reduce Motion the label holds steady at full
/// opacity — exactly the pre-animation rendering.
private struct TranscribingLabel: View {
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
    if animated {
      // ~20 Hz is plenty for a 1.8 s opacity ramp — rendering at the display's
      // full refresh rate would only burn energy (same reasoning as the 30 Hz
      // cap on WaveformBars).
      TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
        label.opacity(breathOpacity(at: timeline.date.timeIntervalSinceReferenceDate))
      }
    } else {
      label
    }
  }

  // Shared with the "Pasted" notice (OverlayView's `.pasted` case) so the
  // processing → pasted hand-off reads as one status line.
  private var label: some View {
    StatusLineText("Transcribing…")
  }

  /// Raised cosine over `breathPeriod`: 1 → `minOpacity` → 1, so the label
  /// eases through the dim point instead of bouncing off it.
  private func breathOpacity(at time: TimeInterval) -> Double {
    let osc = (cos(time / breathPeriod * 2 * .pi) + 1) / 2  // 0...1
    return minOpacity + (1 - minOpacity) * osc
  }
}

/// The "● REC" recording tag: a steady magenta dot + "REC" caption, sitting to
/// the left of the waveform — the native echo of the site demo's magenta pixel
/// tag. Magenta (the brand --hot) reads as the recording indicator while the
/// cyan bars carry the live level.
private struct RecordingTag: View {
  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(OverlayBrandPalette.magenta)
        .frame(width: 5, height: 5)
      Text("REC")
        .font(.system(size: 9, weight: .semibold))
        .tracking(1.2)
        .foregroundStyle(OverlayBrandPalette.magenta)
    }
    .fixedSize()
  }
}

/// A row of bars filling the whole pill that track the *current* mic level — no
/// scrolling history. Bars span the full width (count derived from the available
/// width) and grow from the vertical center; a symmetric envelope keeps the
/// middle tallest so the field reads as one voice "blob". When you're between
/// words the bars breathe with a gentle staggered sine; the breathing fades out
/// as your voice gets louder. Under Reduce Motion the breathing is dropped and
/// heights simply reflect the level.
private struct WaveformBars: View {
  /// Current loudness, 0...1 (MicCapture.linearLevel).
  let level: Float
  /// Whether to run the idle breathing motion (off under Reduce Motion).
  let animated: Bool
  let color: Color

  private let barWidth: CGFloat = 3
  private let barSpacing: CGFloat = 3
  // The REC tag and the enclosing HStack padding now hold the bars clear of the
  // capsule's rounded ends, so the bar field only needs a hair of its own inset.
  private let horizontalInset: CGFloat = 4
  private let verticalInset: CGFloat = 3
  private let minBarHeightFraction: CGFloat = 0.12
  // Compresses the 0...1 level into bar height. Lowish so normal speech already
  // fills much of the pill height; raise toward 2 for shorter bars.
  private let levelGamma: CGFloat = 1.3
  // Height fraction at the far ends of the symmetric envelope (center is 1).
  private let envelopeEdge: CGFloat = 0.45
  // How far a bar travels while idle-breathing.
  private let breathDepth: CGFloat = 0.12

  var body: some View {
    GeometryReader { geo in
      let maxBarHeight = max(1, geo.size.height - verticalInset * 2)
      let usableWidth = max(1, geo.size.width - horizontalInset * 2)
      let count = max(3, Int((usableWidth + barSpacing) / (barWidth + barSpacing)))
      Group {
        if animated {
          // Continuous clock so the idle breathing is smooth and never depends
          // on a one-shot state toggle. Capped at ~30 Hz to match the mic meter
          // (MicCapture.meterInterval) — the level feed and the slow breathing
          // sine can't show anything faster, so rendering at the display's full
          // refresh rate (up to 120 Hz on ProMotion) would only burn energy.
          TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            row(count: count, maxBarHeight: maxBarHeight, time: timeline.date.timeIntervalSinceReferenceDate)
          }
        } else {
          row(count: count, maxBarHeight: maxBarHeight, time: 0)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
  }

  private func row(count: Int, maxBarHeight: CGFloat, time: TimeInterval) -> some View {
    HStack(spacing: barSpacing) {
      ForEach(0..<count, id: \.self) { idx in
        Capsule()
          .fill(color)
          .frame(width: barWidth, height: barHeight(idx, count: count, maxBarHeight: maxBarHeight, time: time))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func barHeight(_ index: Int, count: Int, maxBarHeight: CGFloat, time: TimeInterval) -> CGFloat {
    let weight = envelopeWeight(index, count: count)
    // Voice-driven height: the current level, gamma-shaped, scaled by this bar's
    // envelope weight so the middle leads.
    let voice = pow(CGFloat(max(0, min(1, level))), levelGamma) * weight
    var breath: CGFloat = 0
    // Full breathing when quiet, fading to none once the voice is moderate. Once
    // it's faded out (voice ≥ 0.25) the per-bar sine below would multiply to ~0,
    // so skip it entirely on the louder frames rather than computing-then-zeroing.
    let idleStrength = animated ? max(0, 1 - voice / 0.25) : 0
    if idleStrength > 0 {
      // Per-bar period + phase so the bars shimmer out of sync when idle.
      let period = 0.9 + 0.5 * Double(index % 3) / 2
      let osc = (sin(time / period * 2 * .pi + Double(index)) + 1) / 2  // 0...1
      breath = breathDepth * weight * osc * idleStrength
    }
    let fraction = max(minBarHeightFraction, voice + breath)
    return maxBarHeight * min(1, fraction)
  }

  /// Symmetric raised-sine window: `envelopeEdge` at the ends rising to 1 at the
  /// center, so the bars form a single voice hump filling the pill width.
  private func envelopeWeight(_ index: Int, count: Int) -> CGFloat {
    guard count > 1 else { return 1 }
    let t = CGFloat(index) / CGFloat(count - 1)  // 0...1
    return envelopeEdge + (1 - envelopeEdge) * sin(.pi * t)
  }
}
