import BlurtDesign
import BlurtiOSCore
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
  /// The key's width: as wide as the element shows (`VoiceRowLayout`).
  var width: CGFloat?
  /// The key's touch target is at least this tall — the row's height — so
  /// the whole row under the element is the key, not just the element's box.
  var hitHeight: CGFloat?
  /// Down while the finger is on the key. A gesture state, so a touch the
  /// system takes away lets the key back up; a plain state would hold it down.
  @GestureState private var pressed = false
  @State private var press = MicPressSequencer()
  @State private var pressTask: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.keyboardMotionHeld) private var motionHeld
  @Environment(\.keyboardPalette) private var palette
  private var reduceMotion: Bool { systemReduceMotion || motionHeld }

  var body: some View {
    let state = model.voiceState
    let box = slot.box
    let hit = CGSize(width: width ?? box.width, height: max(box.height, hitHeight ?? 0))
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
    .frame(width: hit.width, height: hit.height)
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: state.phase)
    .scaleEffect(pressed ? DesignTokens.Metrics.voicePressScale : 1)
    .animation(.easeOut(duration: DesignTokens.Motion.press), value: pressed)
    .contentShape(Rectangle())
    .accessibilityLabel(state.accessibilityLabel)
    .accessibilityValue(state.accessibilityValue)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("blurt-mic")
    .onDisappear {
      pressTask?.cancel()
      pressTask = nil
      press = MicPressSequencer()
    }
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .updating($pressed) { _, state, _ in state = true }
        .onChanged { value in
          if press.began() {
            // The press waits a beat, so a swipe that starts on the key (the
            // panel's carousel) never starts a dictation it must then cancel.
            pressTask = Task { [model] in
              try? await Task.sleep(for: KeyboardInteraction.micPressDelay)
              // A touch the system took away in the meantime (the gesture
              // state is down again) presses nothing.
              guard !Task.isCancelled, pressed else {
                press = MicPressSequencer()
                return
              }
              if press.delayFired() { model.micDown() }
            }
          }
          if press.moved(travelled: KeyboardInteraction.micTravelled(value.translation)) {
            pressTask?.cancel()
            pressTask = nil
          }
        }
        .onEnded { value in
          pressTask?.cancel()
          pressTask = nil
          switch press.ended(travelled: KeyboardInteraction.micTravelled(value.translation)) {
          case .tap(let needsDown):
            // A tap quicker than the delay is still a tap.
            if needsDown { model.micDown() }
            model.micUp()
          case .cancelSentPress:
            model.undoPress()
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
