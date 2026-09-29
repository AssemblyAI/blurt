import BlurtEngine
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

  static let height = DesignTokens.Metrics.voicebarHeight

  var body: some View {
    GeometryReader { geo in
      ZStack {
        if model.termDraft != nil {
          TermField(model: model)
            .transition(.opacity)
        } else if !model.hasFullAccess {
          // The one state the orb can't show on its own: without Full Access
          // nothing here can work, and the user has to be told where to go.
          HStack(spacing: DesignTokens.Metrics.voicebarNoteGap) {
            MicControl(model: model, size: DesignTokens.Metrics.orbBar, wave: nil)
            Text("Allow Full Access in Settings → Keyboards")
              .font(.footnote)
              .foregroundStyle(BlurtBrand.errorOrange)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
          .transition(.opacity)
        } else {
          // The wave stays clear of the + at the trailing edge, on both sides so it stays centred.
          let clearance = DesignTokens.Metrics.glyphHit + DesignTokens.Metrics.voicebarAddtermClearance
          MicControl(
            model: model, size: DesignTokens.Metrics.orbBar,
            wave: CGSize(
              width: min(DesignTokens.Metrics.waveBarWidth, geo.size.width - 2 * clearance),  // literal-ok: both sides
              height: DesignTokens.Metrics.waveBarHeight)
          )
          .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(height: Self.height)
    .overlay(alignment: .trailing) {
      if model.termDraft == nil, model.hasFullAccess { AddTermKey(model: model) }
    }
    .animation(.easeInOut(duration: DesignTokens.Motion.termSwap), value: model.termDraft == nil)
  }
}
