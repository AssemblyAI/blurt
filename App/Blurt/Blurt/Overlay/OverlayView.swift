import BlurtEngine
import SwiftUI

struct OverlayView: View {
  // The single source of pill state. The live mic level is *not* read in this
  // body: that would rebuild the whole pill (capsule, shadow, REC tag) on
  // every ~20 Hz meter tick. Only `bridge.state` is read here (via `state`
  // below); the leaf bar view (`WaveformBarsLevel`, under `WaveformMeter`) reads `bridge.level`, so
  // @Observable confines the per-tick invalidation to the bars — the rest of
  // the pill stays stable.
  let bridge: OverlayBridge

  private var state: OverlayUIState { bridge.state }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  // The pill is only on screen while a dictation is happening, always at its full
  // size — it fades in on key-down and out at idle (OverlayWindowController), so
  // there's no collapsed/hover resting state. The size is the panel's pill size
  // (the panel is sized off it plus the shadow margin) so the capsule fills the
  // window exactly — single source of truth lives on OverlayWindowController.
  private var pillSize: CGSize { OverlayWindowController.pillSize }

  // The pill body is a solid, opaque capsule — not Liquid Glass. `.regular` glass
  // is an adaptive material that samples the backdrop to decide its light/dark
  // rendering, and can't do so until it's composited on screen; fading in from
  // alpha 0 it flashed white for a frame over a dark desktop before settling.
  // A fixed fill never adapts, so it fades in the same dark gray on any backdrop.
  // Every state is the same dark gray except `.error`, which keeps a red body as
  // an alarm cue (the ↻ "Try again" content alone shouldn't have to carry it).
  private var fillColor: Color {
    switch state {
    case .error:
      return Color(red: 0.62, green: 0.13, blue: 0.13)
    case .connecting, .recording, .processing, .pasted, .noTarget, .idle:
      return Color(white: 0.16)
    }
  }

  var body: some View {
    content
      .frame(width: pillSize.width, height: pillSize.height)
      // Solid, opaque capsule rather than Liquid Glass: a fixed fill never adapts
      // to the backdrop, so the pill fades in the same dark gray everywhere with
      // no first-frame flash (see `fillColor`). `.animation` below cross-fades the
      // fill on a state change (e.g. into the red error body).
      .background(Capsule().fill(fillColor))
      // A hairline white rim on the fill's edge. A single opaque fill can only
      // separate from one end of the brightness range: the drop shadow below
      // carries light backdrops but is invisible on a dark/black one, where the
      // pill would otherwise lose its silhouette. The ~12% white stroke is
      // near-invisible over light content (it rides the shadow) and draws the
      // capsule's edge over dark content, so the pill reads on any backdrop.
      // strokeBorder insets by half the line width, so it stays inside the frame.
      .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
      // Flatten into one layer before shadowing so the drop shadow takes the
      // capsule's rounded alpha, not the rectangular layer bounds (which renders
      // as a boxy halo, most visible on a white backdrop). The explicit shadow
      // keeps the dark pill separated from light content. The soft falloff
      // spreads to ~2x the radius plus the offset; OverlayWindowController.shadowMargin
      // is sized to contain that so it fades fully to nothing before the panel
      // edge rather than clipping into a line.
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
      .accessibilityIdentifier(UITestIdentifiers.overlayPill)
  }

  @ViewBuilder
  private var content: some View {
    switch state {
    case .idle:
      // Never actually on screen: dismissal keeps the last real state through
      // the fade-out and only settles to idle once the panel is ordered out
      // (OverlayWindowController.dismissPanel). `Color.clear` (not `EmptyView`,
      // which renders nothing — modifiers on it produce no view, so the capsule
      // background would collapse with it) keeps the pill's shape intact for
      // `hide()`'s pre-hide reset.
      Color.clear
    case .connecting:
      // The mic route is still coming up (a Bluetooth input switching profiles):
      // a breathing status line, deliberately without the REC tag or waveform —
      // the "speak now" cues arrive with `.recording`, once audio actually flows.
      ConnectingLabel(animated: !reduceMotion)
        .transition(.opacity)
    case .recording:
      // "● REC" tag beside the live waveform, mirroring the site demo's recording
      // pill (magenta tag + bars). The bars fill the width left of the tag.
      HStack(spacing: 8) {
        RecordingTag(animated: !reduceMotion)
        WaveformMeter(bridge: bridge, animated: !reduceMotion, color: OverlayBrandPalette.cyan)
      }
      .padding(.horizontal, 12)
      .transition(.opacity)
    case .processing:
      // Matches the site demo's "Transcribing…" label (the demo cross-fades REC →
      // Transcribing); cyan echoes the demo's --ice. Cross-fades like the bars.
      // The label breathes (slow opacity pulse) so the wait for the dictation API +
      // paste reads as active work rather than a frozen pill.
      TranscribingLabel(animated: !reduceMotion)
        .transition(.opacity)
    case .error(let message):
      // "Try again" tells the user what to do; the full failure reason is too
      // long for the pill, so expose it on hover. The VoiceOver announcement
      // (OverlayWindowController) speaks the same message for non-sighted users.
      errorPill(help: message)
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
      // Quiet, informational notice: there was no text field to type into, so
      // the transcript went to the clipboard. Styled exactly like "Pasted"
      // (same status-line type and cyan --ice) so it reads as info, not the red
      // error flash. No glyph — the word alone carries it. Hover still exposes
      // the full announcement text.
      StatusLineText("Copied")
        .transition(.opacity)
        .help(state.accessibilityLabel)
    }
  }

  /// The transient `.error` notice: a ↻ glyph and "Try again". Spelled out rather
  /// than parameterized because it's the only notice pill left — `.pasted` and
  /// `.noTarget` moved to `StatusLineText`, and a symbol/tint/label knob for one
  /// caller made the reader check three arguments to learn what the pill says.
  /// `help` is the hover tooltip — pass the state's message so it stays the same
  /// string the window controller announces to VoiceOver (the wording lives in one
  /// place, `OverlayUIState`).
  private func errorPill(help: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.clockwise")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
      Text("Try again")
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 4)
    .transition(.opacity)
    .help(help)
  }
}
