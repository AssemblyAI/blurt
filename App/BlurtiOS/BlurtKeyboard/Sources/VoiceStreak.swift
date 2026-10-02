import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// Candidate C — the streak. The flare as the meter: at rest a hairline the
/// width of the box with one bright point at its centre (the photograph's
/// star). While recording the point blooms into a horizontal light streak
/// whose reach and brightness follow the level, with a prismatic fringe at
/// its ends. While something is happening a short streak sweeps the line.
/// When the words land the vertical arm of the cross flashes through once.
/// Nothing else. (A line that grows can read as a loading bar — the risk
/// this candidate carries, on purpose, so it is seen and not argued.)
struct VoiceStreak: View {
  let inputs: VoiceElementInputs

  private typealias Metrics = DesignTokens.Metrics

  var body: some View {
    let box = inputs.slot.box
    TimelineView(.animation(minimumInterval: keyboardAnimationInterval, paused: !inputs.animated)) { timeline in
      let now = inputs.animated ? timeline.date : Date(timeIntervalSinceReferenceDate: 0)
      Canvas { context, size in
        Self.draw(&context, size: size, inputs: inputs, now: now)
      }
    }
    .frame(width: box.width, height: box.height)
    .opacity(inputs.state.isReady ? 1 : Metrics.opacityOff)
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: inputs.state.isReady)
    .accessibilityHidden(true)
  }

  private static func draw(_ context: inout GraphicsContext, size: CGSize, inputs: VoiceElementInputs, now: Date) {
    let state = inputs.state
    let palette = inputs.palette
    let midY = size.height / 2
    let lineColour: Color =
      switch state.phase {
      case .error: palette.notice
      case .pasted, .copied: palette.signal
      case .idle, .connecting, .recording, .processing: palette.keyTextSecondary
      }
    // The hairline.
    let line = Metrics.streakLine
    context.fill(
      Path(CGRect(x: 0, y: midY - line / 2, width: size.width, height: line)),  // literal-ok: centred on the line
      with: .color(lineColour.opacity(Metrics.opacityHairline)))
    if state.isRecording {
      streak(&context, size: size, level: state.level, palette: palette)
    } else if state.isWorking, inputs.animated {
      sweep(&context, size: size, time: now.timeIntervalSinceReferenceDate, palette: palette)
    }
    // The point.
    let point = Metrics.streakPoint
    let half = point / 2
    let dot = CGRect(x: size.width / 2 - half, y: midY - half, width: point, height: point)  // literal-ok: centred
    context.fill(Path(ellipseIn: dot), with: .color(state.isRecording ? DesignTokens.Brand.white : palette.keyText))
    if let progress = VoiceClock.landing(landedAt: inputs.landedAt, now: now) {
      flash(&context, size: size, progress: progress)
    }
  }

  /// The streak: from the centre, both ways, as far as the voice reaches,
  /// white at the heart, the signal along it, a violet fringe at the tips.
  private static func streak(_ context: inout GraphicsContext, size: CGSize, level: Float, palette: KeyboardPalette) {
    let midY = size.height / 2
    let reach = size.width * CGFloat(pow(Double(level), 0.7))  // literal-ok: the ear's curve
    let thick = Metrics.streakHeight
    let x = (size.width - reach) / 2
    let rect = CGRect(x: x, y: midY - thick / 2, width: reach, height: thick)  // literal-ok: centred
    context.fill(
      Path(roundedRect: rect, cornerRadius: thick / 2),  // literal-ok: capsule ends
      with: .linearGradient(
        Gradient(stops: [
          .init(color: DesignTokens.Brand.violetPeriwinkle.opacity(0), location: 0),
          .init(color: palette.signal, location: 0.35),  // literal-ok: where the fringe gives way to the signal
          .init(color: DesignTokens.Brand.white, location: 0.5),  // literal-ok: the centre
          .init(color: palette.signal, location: 0.65),  // literal-ok: mirrored
          .init(color: DesignTokens.Brand.violetPeriwinkle.opacity(0), location: 1),
        ]),
        startPoint: CGPoint(x: rect.minX, y: midY), endPoint: CGPoint(x: rect.maxX, y: midY)))
  }

  /// A short streak sweeping the line back and forth while the mic comes up
  /// or the words are made.
  private static func sweep(
    _ context: inout GraphicsContext, size: CGSize, time: TimeInterval, palette: KeyboardPalette
  ) {
    let midY = size.height / 2
    let phase = VoiceClock.sheen(time: time, working: true)
    let position = phase < 0.5 ? phase * 2 : 2 - phase * 2  // literal-ok: there and back
    let length = size.width * 0.25  // literal-ok: a quarter of the line
    let x = (size.width - length) * position
    let thick = Metrics.streakHeight
    let rect = CGRect(x: x, y: midY - thick / 2, width: length, height: thick)  // literal-ok: centred
    context.fill(
      Path(roundedRect: rect, cornerRadius: thick / 2),  // literal-ok: capsule ends
      with: .linearGradient(
        Gradient(colors: [palette.signal.opacity(0), palette.signal, palette.signal.opacity(0)]),
        startPoint: CGPoint(x: rect.minX, y: midY), endPoint: CGPoint(x: rect.maxX, y: midY)))
  }

  /// The landing: the cross's vertical arm flashes through the point, and
  /// the line lights with it.
  private static func flash(_ context: inout GraphicsContext, size: CGSize, progress: Double) {
    let midY = size.height / 2
    let alpha = Metrics.opacityGlint * (1 - progress)
    let arm = size.height * Metrics.streakArm
    var path = Path()
    path.move(to: CGPoint(x: size.width / 2, y: midY - arm / 2))
    path.addLine(to: CGPoint(x: size.width / 2, y: midY + arm / 2))
    context.stroke(path, with: .color(DesignTokens.Brand.white.opacity(alpha)), lineWidth: Metrics.grilleGlintWidth)
    let line = Metrics.streakLine
    context.fill(
      Path(CGRect(x: 0, y: midY - line / 2, width: size.width, height: line)),  // literal-ok: centred on the line
      with: .color(DesignTokens.Brand.white.opacity(alpha)))
  }
}
