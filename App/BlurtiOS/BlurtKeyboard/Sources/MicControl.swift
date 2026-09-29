import BlurtEngine
import SwiftUI

/// The mic key is the brand orb, and it says everything without a word or a
/// glyph. Finger down starts, finger up decides tap (latched) or hold
/// (push-to-talk) — `KeyboardModel` runs the engine's gate, `MicPressSequencer`
/// the press's steps, `VoiceState` what shows. What it does: dimmed when
/// Blurt isn't ready (no Full Access, or the app isn't listening; the tap
/// opens Blurt); on a tap the ring sweeps as the app's orb does while the mic
/// comes up; then the orb dissipates — swells a little, softens to a haze, is
/// gone — and in its place the voice is a thin wave, flat on the surface, for
/// as long as you talk, and the wave is the key; on the stop the wave fades
/// and the orb condenses back with the ring sweeping while the words come;
/// then a green ring for a moment when they landed (the violet drop with it),
/// a clipboard on a green ring when they went to the clipboard instead, an
/// orange ring and an exclamation mark when something failed. Each also has
/// its haptic.
///
/// Nothing snaps or springs: the orb and the wave cross over `wave-fade`,
/// every other change over `state-fade`. Only the press itself answers at
/// once.
struct MicControl: View {
  var model: KeyboardModel
  var size: CGFloat
  /// The wave the orb dissipates into while recording — wide and slim —
  /// or nil for none (the orb stays). The key's frame is the wave's width
  /// throughout, so nothing moves while the two cross; only the circle
  /// answers a touch until the wave is up, then the wave's band does.
  var wave: CGSize?
  @State private var pressed = false
  @State private var press = MicPressSequencer()
  @State private var pressTask: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.keyboardMotionHeld) private var motionHeld
  @Environment(\.keyboardPalette) private var palette
  private var reduceMotion: Bool { systemReduceMotion || motionHeld }

  var body: some View {
    let state = model.voiceState
    let showsWave = state.isRecording && wave != nil
    ZStack {
      if let wave, state.isRecording {
        WaveformMeter(
          level: state.level, animated: !reduceMotion, color: palette.signal,
          barWidth: WaveformMeter.slimBar, barSpacing: WaveformMeter.slimGap
        )
        .frame(width: wave.width, height: wave.height)
        .transition(.opacity)
      } else {
        PrismOrb(mood: Self.mood(state), landedAt: model.resultLandedAt, animated: !reduceMotion)
          .clipShape(Circle())
          .overlay { ring(state) }
          .frame(width: size, height: size)
          .saturation(state.isReady ? 1 : DesignTokens.Metrics.opacityDimSaturation)
          .opacity(state.isReady ? 1 : DesignTokens.Metrics.opacityDim)
          .transition(reduceMotion ? .opacity : .dissipate(size: size))
      }
      if let glyph = state.glyph {
        Image(systemName: Self.symbol(glyph))
          .font(
            .system(size: size * DesignTokens.Typography.ratioOrbGlyph, weight: DesignTokens.Typography.weightOrbGlyph)
          )
          .foregroundStyle(.white)
          .transition(.opacity)
      }
    }
    .frame(width: wave.map { max($0.width, size) } ?? size, height: size)
    .animation(.easeInOut(duration: DesignTokens.Motion.waveFade), value: state.isRecording)
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: state.phase)
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: state.isReady)
    .scaleEffect(pressed ? DesignTokens.Metrics.pressScale : 1)
    .animation(.easeOut(duration: DesignTokens.Motion.press), value: pressed)
    .contentShape(showsWave ? AnyShape(Capsule()) : AnyShape(Circle()))
    .accessibilityLabel(state.accessibilityLabel)
    .accessibilityValue(state.accessibilityValue)
    .accessibilityAddTraits(.isButton)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          pressed = true
          if press.began() {
            // The press waits a beat, so a swipe that starts on the orb (the
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

  /// The ring: the app orb's sweep (one turn per 1.6 s, engine geometry)
  /// while the mic comes up and while the words come; still, and solid green
  /// or orange, for a notice; still while recording.
  @ViewBuilder private func ring(_ state: VoiceState) -> some View {
    let width = state.isWorking || state.isNotice ? DesignTokens.Metrics.ringActive : DesignTokens.Metrics.ringStill
    switch state.ring {
    case .sweeping where !reduceMotion:
      TimelineView(.animation(minimumInterval: keyboardAnimationInterval)) { timeline in
        Circle()
          .strokeBorder(BlurtBrand.orbRingGradient, lineWidth: width)
          .rotationEffect(
            .degrees(
              MeterBarGeometry.rotationDegrees(
                time: timeline.date.timeIntervalSinceReferenceDate, period: KeyboardMotion.ringPeriod)))
      }
    case .solid(.error):
      Circle().strokeBorder(BlurtBrand.errorOrange, lineWidth: width)
    case .solid(.ok):
      Circle().strokeBorder(BlurtBrand.greenOnDark, lineWidth: width)
    case .still, .sweeping:
      Circle().strokeBorder(BlurtBrand.orbRingGradient, lineWidth: width)
    }
  }

  /// The orb's story from the phase: green, greener with the voice; the
  /// violet drop is keyed to the moment the words landed, not to a phase.
  static func mood(_ state: VoiceState) -> PrismOrb.Mood {
    guard state.isReady else { return .off }
    switch state.phase {
    case .idle, .error, .pasted, .copied: return .idle
    case .connecting: return .listening(level: 0)
    case .recording: return .listening(level: state.level)
    case .processing: return .working
    }
  }

  private static func symbol(_ glyph: VoiceState.Glyph) -> String {
    switch glyph {
    case .clipboard: "doc.on.clipboard"
    case .exclamation: "exclamationmark"
    }
  }
}
