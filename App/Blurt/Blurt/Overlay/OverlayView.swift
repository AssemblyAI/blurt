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
  // A fixed fill never adapts, so it fades in the same brand ink on any backdrop.
  // Every state shares that one body, `.error` included: the design moves the
  // alarm off the capsule and into the word, which is orange rather than the
  // green the other states use (see `errorPill`). One fill for every state also
  // means the cross-fade below now only ever animates content, never the body.
  private let fillColor = BlurtBrand.ink

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
      // The mic is coming up; nothing is being captured yet. Shaped like
      // "Transcribing" — orb with the ring sweeping, then the label — so the
      // two waits look like one thing, and deliberately *not* the meter, which
      // would cue the user to speak into a mic that isn't delivering yet.
      //
      // On a built-in mic this is on screen for a frame or two, inside the
      // pill's own 0.08 s fade-in, so it blends into the appearance rather than
      // flashing; on a Bluetooth route it holds for as long as the link takes,
      // which is the whole point.
      waitingContent("Connecting")
        .transition(.opacity)
    case .recording:
      // The orb beside the live waveform, its ring sweeping as it does in every
      // other state — the orb is one object and doesn't change behaviour with
      // the content next to it. The meter carries the level; the ring carries
      // "still running".
      HStack(spacing: Self.contentSpacing) {
        BrandOrb(animated: !reduceMotion)
        // Fills what's left, which is now about half what it used to be —
        // the pill itself shrank rather than the meter being capped inside it.
        // Capping it left the right half of the capsule empty; shrinking the
        // capsule gets the same short bar row with no dead space. The row
        // derives its bar count from the width it's given, so this is fewer
        // bars rather than squashed ones.
        WaveformMeter(bridge: bridge, animated: !reduceMotion, color: BlurtBrand.greenOnDark)
      }
      .padding(.horizontal, Self.contentInset)
      .transition(.opacity)
    case .processing:
      // The meter stops and the ring takes over as the activity cue, so the
      // wait for the dictation API + paste reads as active work rather than a
      // frozen pill. The orb itself doesn't move across the hand-off — only
      // what's beside it changes — which is what makes the pill read as one
      // surface progressing rather than three unrelated states.
      waitingContent("Transcribing")
        .transition(.opacity)
    case .error(let message):
      // "Try again" tells the user what to do; the full failure reason is too
      // long for the pill, so expose it on hover. The VoiceOver announcement
      // (OverlayWindowController) speaks the same message for non-sighted users.
      errorPill(help: message)
    case .pasted:
      // Quiet, informational notice confirming the transcript was typed into the
      // focused field. Styled exactly like "Transcribing…" (same type, tracking,
      // and brand green) so the processing → pasted hand-off reads as one
      // continuous status line rather than a new kind of alert. No glyph — the
      // word alone carries it. Hover still exposes the full announcement text.
      StatusLineText("Pasted")
        .transition(.opacity)
        .help(state.accessibilityLabel)
    case .noTarget:
      // Quiet, informational notice: there was no text field to type into, so
      // the transcript went to the clipboard. Styled exactly like "Pasted"
      // (same status-line type and brand green) so it reads as info, not the red
      // error flash. No glyph — the word alone carries it. Hover still exposes
      // the full announcement text.
      StatusLineText("Copied")
        .transition(.opacity)
        .help(state.accessibilityLabel)
    }
  }

  /// The pill's inner inset and the gap between the orb and what follows it.
  private static let contentInset: CGFloat = 12
  private static let contentSpacing: CGFloat = 8

  /// The shape both waits share: the brand orb, then the status word in place
  /// of the meter. One builder rather than two call sites that happen to match,
  /// so "Connecting" and "Transcribing" can't drift into two different layouts
  /// — the whole point of the orb is that it doesn't move between them.
  private func waitingContent(_ text: String) -> some View {
    HStack(spacing: 8) {
      BrandOrb(animated: !reduceMotion)
      StatusLineText(text)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Self.contentInset)
  }

  /// The transient `.error` notice: the word alone, in the design's orange, on
  /// the same ink body as every other state.
  ///
  /// The orange *is* the alarm — this pill used to turn red and say "↻ Try
  /// again", and the design trades that for a quieter, on-brand treatment. The
  /// instruction is no longer on the capsule, so the actual failure reason
  /// matters more than before: it stays on hover (`help`) and in the VoiceOver
  /// announcement, both from `OverlayUIState` so the wording lives in one place.
  private func errorPill(help: String) -> some View {
    StatusLineText("Error", color: BlurtBrand.errorOrange)
      .padding(.horizontal, 4)
      .transition(.opacity)
      .help(help)
  }
}
