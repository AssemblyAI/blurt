import SwiftUI

/// The keyboard's voice row, and the only place voice lives: the orb, which
/// is the mic key — tap to start and stop, hold to talk — dissipating into
/// the wave while recording. No words: the orb's ring and colour, or the
/// wave, say what is happening, and the haptics confirm it (see `MicControl`).
/// Beside it, a small
/// + for the one thing people want the instant Blurt mishears a word: add it
/// as a key term. The bar then becomes the field the keys type into.
struct VoiceBar: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette
  @Environment(\.voiceElementKind) private var kind

  static let height = DesignTokens.Metrics.voicebarHeight

  var body: some View {
    GeometryReader { geo in
      ZStack {
        if model.termDraft != nil {
          TermField(model: model)
            .transition(.opacity)
        } else if !model.hasFullAccess {
          // The one state the element can't show on its own: without Full
          // Access nothing here can work, and the user has to be told where
          // to go. The line is the key: a tap opens Blurt, whose checklist
          // says the rest.
          Button {
            model.openApp()
          } label: {
            Text("Allow Full Access in Settings")
              .font(.footnote)
              .foregroundStyle(palette.notice)
              .lineLimit(1)
              .minimumScaleFactor(0.8)  // literal-ok: the note may shrink a little on a narrow phone
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .buttonStyle(KeyPressStyle())
          .accessibilityLabel("Start Blurt")
          .transition(.opacity)
        } else {
          // The element and the + together, centred on what shows: the mic
          // key is as wide as the element is (never narrower than a key, so
          // the ribs asleep are still a target), the + a clearance beside it.
          // When the ribs wake into the wave the + slides out of its way.
          let plus = DesignTokens.Metrics.glyphHit + DesignTokens.Metrics.voicebarAddtermClearance
          let recording = model.voiceState.isRecording
          let shown = kind.visibleWidth(slot: .bar, recording: recording)
          let width = min(max(shown, DesignTokens.Metrics.keyMinWidth), geo.size.width - plus)
          HStack(spacing: DesignTokens.Metrics.voicebarAddtermClearance) {
            MicControl(model: model, slot: .bar, width: width)
            AddTermKey(model: model)
          }
          .animation(.easeInOut(duration: DesignTokens.Motion.waveFade), value: recording)
          .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(height: Self.height)
    .animation(.easeInOut(duration: DesignTokens.Motion.termSwap), value: model.termDraft == nil)
  }
}
