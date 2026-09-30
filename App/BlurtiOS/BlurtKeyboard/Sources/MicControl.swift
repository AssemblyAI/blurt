import SwiftUI

/// The mic key. Finger down starts, finger up decides tap (latched) or hold
/// (push-to-talk) — `KeyboardModel` runs the engine's gate,
/// `MicPressSequencer` the press's steps, `VoiceState` what shows, and the
/// voice element draws it (`VoiceElementView`): dimmed when Blurt isn't
/// ready (the tap opens Blurt), working while the mic comes up and the
/// words are made, the meter while you talk, a glint when the words land,
/// orange when something failed. Only the two notices that need saying carry
/// a glyph — a clipboard when the words went there, an exclamation mark on a
/// failure. Each state also has its haptic.
///
/// Nothing snaps or springs: every change on the key fades over `state-fade`.
/// Only the press itself answers at once.
struct MicControl: View {
  var model: KeyboardModel
  let slot: VoiceSlot
  /// A narrower box than the slot's, when the bar hasn't the room.
  var width: CGFloat?
  @State private var pressed = false
  @State private var press = MicPressSequencer()
  @State private var pressTask: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.keyboardMotionHeld) private var motionHeld
  @Environment(\.keyboardPalette) private var palette
  private var reduceMotion: Bool { systemReduceMotion || motionHeld }

  var body: some View {
    let state = model.voiceState
    let box = CGSize(width: width ?? slot.box.width, height: slot.box.height)
    ZStack {
      VoiceElementView(
        inputs: VoiceElementInputs(
          state: state, landedAt: model.resultLandedAt, animated: !reduceMotion, palette: palette, slot: slot))
      if let glyph = state.glyph {
        Image(systemName: Self.symbol(glyph))
          .font(
            .system(
              size: box.height * DesignTokens.Typography.ratioVoiceGlyph,
              weight: DesignTokens.Typography.weightVoiceGlyph)
          )
          .foregroundStyle(palette.keyText)
          .transition(.opacity)
      }
    }
    .frame(width: box.width, height: box.height)
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: state.phase)
    .scaleEffect(pressed ? DesignTokens.Metrics.voicePressScale : 1)
    .animation(.easeOut(duration: DesignTokens.Motion.press), value: pressed)
    .contentShape(Rectangle())
    .accessibilityLabel(state.accessibilityLabel)
    .accessibilityValue(state.accessibilityValue)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("blurt-mic")
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          pressed = true
          if press.began() {
            // The press waits a beat, so a swipe that starts on the key (the
            // panel's carousel) never starts a dictation it must then cancel.
            pressTask = Task { [model] in
              try? await Task.sleep(for: KeyboardInteraction.micPressDelay)
              guard !Task.isCancelled else { return }
              if press.delayFired() { model.micDown() }
            }
          }
          if press.moved(travelled: KeyboardInteraction.micTravelled(value.translation)) {
            pressTask?.cancel()
            pressTask = nil
          }
        }
        .onEnded { value in
          pressed = false
          pressTask?.cancel()
          pressTask = nil
          switch press.ended(travelled: KeyboardInteraction.micTravelled(value.translation)) {
          case .tap(let needsDown):
            // A tap quicker than the delay is still a tap.
            if needsDown { model.micDown() }
            model.micUp()
          case .cancelSentPress:
            model.cancel()
          case .nothing:
            break
          }
        }
    )
  }

  private static func symbol(_ glyph: VoiceState.Glyph) -> String {
    switch glyph {
    case .clipboard: "doc.on.clipboard"
    case .exclamation: "exclamationmark"
    }
  }
}
