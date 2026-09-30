import SwiftUI

/// The keyboard's voice row, and the only place voice lives: the orb, which
/// is the mic key — tap to start and stop, hold to talk — dissipating into
/// the wave while recording. No words: the orb's ring and colour, or the
/// wave, say what is happening, and the haptics confirm it (see `MicControl`).
/// Beside it, a small
/// + for the one thing people want the instant Blurt mishears a word: add it
/// as a key term. The bar then becomes the field the keys type into — or,
/// when a word is highlighted in the text, the + is already a chip holding
/// that word, and one tap adds it (`AddTermKey`).
struct VoiceBar: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette
  @Environment(\.voiceElementKind) private var kind
  @Environment(\.layoutDirection) private var direction

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
          // When the ribs wake into the wave the + slides out of its way. A
          // highlighted word makes the + a chip: the bar keeps it a minimum,
          // the element gives way, and the chip hugs its word inside what is
          // left, so the pair stays centred.
          let clearance = DesignTokens.Metrics.voicebarAddtermClearance
          let chip = model.selectedTerm != nil
          let beside = chip ? DesignTokens.Metrics.addtermChipMinWidth : DesignTokens.Metrics.glyphHit
          let recording = model.voiceState.isRecording
          let shown = kind.visibleWidth(slot: .bar, recording: recording)
          let width = min(max(shown, DesignTokens.Metrics.keyMinWidth), geo.size.width - beside - clearance)
          // At the right edge the + comes first, so the mic is the thing
          // at the edge and the + sits on its inner side.
          HStack(spacing: clearance) {
            if model.micAlignment.plusLeads(in: direction) { AddTermKey(model: model) }
            MicControl(model: model, slot: .bar, width: width)
            if !model.micAlignment.plusLeads(in: direction) { AddTermKey(model: model) }
          }
          .animation(.easeInOut(duration: DesignTokens.Motion.waveFade), value: recording)
          .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: chip)
          .transition(.opacity)
        }
      }
      // The pair sits where Settings put the mic — the middle, or the edge
      // under the thumb (`MicAlignment`); the field and the note fill the row.
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.micAlignment.alignment(in: direction))
    }
    .frame(height: Self.height)
    .animation(.easeInOut(duration: DesignTokens.Motion.termSwap), value: model.termDraft == nil)
  }
}
