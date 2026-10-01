import SwiftUI

/// The keyboard's voice row, and the only place voice lives in the bar and
/// the full keyboard: the mic key — tap to start and stop, hold to talk —
/// with the small + beside it for the one thing people want the instant
/// Blurt mishears a word: add it as a key term. The row is `VoiceRow`; this
/// swaps it for the key-term field the keys type into, or for the one note
/// the element can't carry (no Full Access).
struct VoiceBar: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette

  static let height = DesignTokens.Metrics.voicebarHeight

  var body: some View {
    ZStack {
      if model.termDraft != nil {
        TermField(model: model)
          .transition(.opacity)
      } else if !model.hasFullAccess {
        // Without Full Access nothing here can work, and the user has to be
        // told where to go. The line is the key: a tap opens Blurt, whose
        // checklist says the rest.
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
        VoiceRow(model: model, slot: .bar, height: Self.height)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: Self.height)
    .animation(.easeInOut(duration: DesignTokens.Motion.termSwap), value: model.termDraft == nil)
  }
}
