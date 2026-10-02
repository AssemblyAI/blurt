import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// Candidate B — the ribs. The mic at rest is a short block of vertical ribs:
/// the thin wave's own bars, still, under a symmetric envelope — the art-deco
/// grille of a Shure 55, the ribbon of an RCA 77. While recording the ribs
/// are the wave: they widen to the box and follow the voice. So there is no
/// circle anywhere, ever, and the element the recording shows is the one
/// that was there all along. A sheen passes over the ribs at rest; a white
/// glint runs them when the words land; a failure turns them orange.
struct VoiceRibs: View {
  let inputs: VoiceElementInputs

  private typealias Metrics = DesignTokens.Metrics

  var body: some View {
    let state = inputs.state
    let box = inputs.slot.box
    let awake = state.isRecording
    let waveHeight: CGFloat =
      switch inputs.slot {
      case .bar: Metrics.waveBarHeight
      case .panel: Metrics.wavePanelHeight
      case .home: Metrics.waveHomeHeight
      }
    ZStack {
      if awake {
        WaveformMeter(
          level: state.level, animated: inputs.animated, color: inputs.palette.signal,
          barWidth: WaveformMeter.slimBar, barSpacing: WaveformMeter.slimGap
        )
        .frame(width: box.width, height: waveHeight)
        .transition(.opacity)
      } else {
        TimelineView(.animation(minimumInterval: keyboardAnimationInterval, paused: !inputs.animated)) { timeline in
          let now = inputs.animated ? timeline.date : Date(timeIntervalSinceReferenceDate: 0)
          Canvas { context, size in
            Self.ribs(&context, size: size, inputs: inputs, now: now)
          }
        }
        .frame(width: Metrics.ribsRestWidth, height: Metrics.ribsRestHeight)
        .transition(.opacity)
      }
    }
    .frame(width: box.width, height: box.height)
    .animation(.easeInOut(duration: DesignTokens.Motion.waveFade), value: awake)
    .opacity(state.isReady ? 1 : Metrics.opacityOff)
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: state.isReady)
    .overlay {
      TimelineView(.animation(minimumInterval: keyboardAnimationInterval, paused: !inputs.animated)) { timeline in
        Canvas { context, size in
          if let progress = VoiceClock.landing(landedAt: inputs.landedAt, now: timeline.date) {
            Self.glint(&context, size: size, progress: progress)
          }
        }
      }
      .allowsHitTesting(false)
    }
    .accessibilityHidden(true)
  }

  /// The ribs asleep: bars at the wave's pitch under a cosine envelope, in
  /// the face's quiet legend colour (orange for a failure, green for a
  /// landing), with the sheen passing over them.
  private static func ribs(_ context: inout GraphicsContext, size: CGSize, inputs: VoiceElementInputs, now: Date) {
    let state = inputs.state
    let pitch = WaveformMeter.slimBar + WaveformMeter.slimGap
    let count = max(1, Int((size.width + WaveformMeter.slimGap) / pitch))
    let inset = (size.width - CGFloat(count) * pitch + WaveformMeter.slimGap) / 2  // literal-ok: centred
    let time = now.timeIntervalSinceReferenceDate
    let sheen = VoiceClock.sheen(time: time, working: state.isWorking)
    let colour: Color
    switch state.phase {
    case .error: colour = inputs.palette.notice
    case .pasted, .copied: colour = inputs.palette.signal
    default: colour = inputs.palette.keyTextSecondary
    }
    for index in 0..<count {
      let unit = (Double(index) + 0.5) / Double(count)
      let envelope = 0.55 + 0.45 * sin(unit * .pi)  // literal-ok: the ribs' shoulder, a cosine window
      let height = size.height * envelope
      let x = inset + CGFloat(index) * pitch
      var opacity = 1.0
      if inputs.animated, state.isReady {
        // The sheen: a band of light 0.18 wide passing rib to rib, running
        // past both ends — still when Blurt isn't ready.
        let distance = abs(unit - sheen * 1.4 + 0.2)
        if distance < 0.18 { opacity += Metrics.opacitySheen * (1 - distance / 0.18) * 2 }
      }
      let bar = Metrics.waveBar
      let rect = CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height)  // literal-ok: centred
      context.fill(
        Path(roundedRect: rect, cornerRadius: bar / 2),  // literal-ok: capsule ends
        with: .color(colour.opacity(min(1, opacity))))
    }
  }

  private static func glint(_ context: inout GraphicsContext, size: CGSize, progress: Double) {
    let alpha = Metrics.opacityGlint * (1 - progress)
    let x = size.width * progress
    var path = Path()
    path.move(to: CGPoint(x: x, y: 0))
    path.addLine(to: CGPoint(x: x, y: size.height))
    context.stroke(path, with: .color(DesignTokens.Brand.white.opacity(alpha)), lineWidth: Metrics.grilleGlintWidth)
  }
}
