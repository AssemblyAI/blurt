import BlurtEngine
import SwiftUI

/// Candidate A — the grille. A dot-matrix mic head: a lattice of small dots
/// in a rectangle with the brand's corners, reading as a mic grille, a
/// rhinestone mesh and the brand's halftone grain at once. It never changes
/// shape; only its dots light. At rest a slow sheen crosses it, the chrome
/// catching light. While recording the lattice is the meter: columns light
/// bottom-up with the level in stepped green (the brand's dithered gradient,
/// an LED VU), and on the peaks a few dots flash white — the facets
/// glistening. While the mic comes up or the words are made, one lit dot
/// runs the perimeter on the ring's cadence. When the words land a thin
/// white cross glint sweeps across it once; a failure turns it orange.
struct VoiceGrille: View {
  let inputs: VoiceElementInputs

  private typealias Metrics = DesignTokens.Metrics

  var body: some View {
    let box = Self.box(inputs.slot)
    TimelineView(.animation(minimumInterval: keyboardAnimationInterval, paused: !inputs.animated)) { timeline in
      let now = inputs.animated ? timeline.date : Date(timeIntervalSinceReferenceDate: 0)
      Canvas(rendersAsynchronously: true) { context, size in
        draw(&context, size: size, now: now)
      }
    }
    .frame(width: box.width, height: box.height)
    .opacity(inputs.state.isReady ? 1 : Metrics.opacityOff)
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: inputs.state.isReady)
    .accessibilityHidden(true)
  }

  static func box(_ slot: VoiceSlot) -> CGSize {
    switch slot {
    case .bar: CGSize(width: Metrics.grilleBarWidth, height: Metrics.grilleBarHeight)
    case .panel: CGSize(width: Metrics.grillePanelWidth, height: Metrics.grillePanelHeight)
    case .home: CGSize(width: Metrics.grilleHomeWidth, height: Metrics.grilleHomeHeight)
    }
  }

  private func draw(_ context: inout GraphicsContext, size: CGSize, now: Date) {
    let state = inputs.state
    let palette = inputs.palette
    let time = now.timeIntervalSinceReferenceDate
    let pitch = Metrics.grillePitch
    let dot = Metrics.grilleDot
    let lattice = Self.lattice(size, pitch: pitch)
    let columns = lattice.columns
    let rows = lattice.rows
    let origin = lattice.origin
    // The lattice is the meter: the engine's envelope and idle wave give each
    // column a height, quantised to whole dots from the bottom.
    let meter = MeterBarRow(count: columns, availableHeight: size.height)
    let level = state.isRecording ? state.level : 0
    let sheenPhase = VoiceClock.sheen(time: time, working: state.isWorking && !state.isRecording)
    let sheenBand = size.width * Metrics.grilleSheenWidth
    let sheenCentre = sheenPhase * (size.width + size.height + sheenBand) - sheenBand
    let runner =
      state.isWorking && !state.isRecording ? Self.runnerIndex(time: time, columns: columns, rows: rows) : nil
    let (glintTick, glintPhase) = Self.glintClock(time)
    let (restColour, restOpacity) = Self.rest(state: state, palette: palette)
    let sheen = inputs.animated && !state.isRecording ? (centre: sheenCentre, band: sheenBand) : nil
    for column in 0..<columns {
      let height = state.isRecording ? meter.height(at: column, level: level, time: time, animated: inputs.animated) : 0
      let lit = state.isRecording ? Int((height / size.height * CGFloat(rows)).rounded()) : 0
      let glints = Double(level) > 0.35 && VoiceClock.hash(column, glintTick) < Double(level) * 0.5  // literal-ok: how often a facet catches the light
      for row in 0..<rows {
        let x = origin.x + CGFloat(column) * pitch
        let y = origin.y + CGFloat(row) * pitch
        let fromBottom = rows - row
        var colour = restColour
        var opacity = restOpacity
        if lit > 0, fromBottom <= lit {
          colour = palette.signal
          opacity = 1
          // The top of a loud column glistens: a facet catches the light.
          if fromBottom == lit, glints {
            colour = DesignTokens.Brand.white
            opacity = 1 - glintPhase
          }
        } else if let runner, runner == Self.perimeterIndex(column: column, row: row, columns: columns, rows: rows) {
          colour = palette.signal
          opacity = 1
        } else if let sheen {
          // The sheen: a diagonal band of light passing over the lattice.
          let distance = abs(x + y - sheen.centre)
          if distance < sheen.band / 2 { opacity += Metrics.opacitySheen * (1 - distance / (sheen.band / 2)) }  // literal-ok: half the band each side
        }
        let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)  // literal-ok: centred dots
        context.fill(Path(ellipseIn: rect), with: .color(colour.opacity(min(1, opacity))))
      }
    }
    if let progress = VoiceClock.landing(landedAt: inputs.landedAt, now: now) {
      Self.glint(&context, size: size, progress: progress)
    }
  }

  /// How many dots fit, and where the first one sits so the lattice is centred.
  private struct Lattice {
    let columns: Int
    let rows: Int
    let origin: CGPoint
  }

  private static func lattice(_ size: CGSize, pitch: CGFloat) -> Lattice {
    let columns = max(1, Int(size.width / pitch))
    let rows = max(1, Int(size.height / pitch))
    return Lattice(
      columns: columns, rows: rows,
      origin: CGPoint(
        x: (size.width - CGFloat(columns - 1) * pitch) / 2, y: (size.height - CGFloat(rows - 1) * pitch) / 2))  // literal-ok: centred
  }

  /// Which flash we are in, and how far through it.
  private static func glintClock(_ time: TimeInterval) -> (Int, Double) {
    let life = DesignTokens.Motion.glintLife
    return (Int(time / life), time.truncatingRemainder(dividingBy: life) / life)
  }

  /// The lattice's colour when nothing is lit: quiet at rest, green for a
  /// landing, orange for a failure.
  private static func rest(state: VoiceState, palette: KeyboardPalette) -> (Color, Double) {
    switch state.phase {
    case .error: (palette.notice, 1)
    case .pasted, .copied: (palette.signal, 1)
    case .idle, .connecting, .recording, .processing: (palette.keyText, Metrics.opacityGrilleRest)
    }
  }

  /// The perimeter dot the runner is on while something is happening.
  private static func runnerIndex(time: TimeInterval, columns: Int, rows: Int) -> Int {
    let perimeter = max(1, 2 * columns + 2 * rows - 4)
    let phase = VoiceClock.sheen(time: time, working: true)
    return Int(phase * Double(perimeter)) % perimeter
  }

  /// A dot's place on the perimeter, clockwise from the top-left, or nil inside.
  private static func perimeterIndex(column: Int, row: Int, columns: Int, rows: Int) -> Int? {
    if row == 0 { return column }
    if column == columns - 1 { return columns - 1 + row }
    if row == rows - 1 { return columns - 1 + rows - 1 + (columns - 1 - column) }
    if column == 0 { return 2 * (columns - 1) + rows - 1 + (rows - 1 - row) }
    return nil
  }

  /// The cross glint: a thin white four-point flare that sweeps left to right
  /// as the words land, its vertical arm taller than the grille, with a
  /// faint prismatic fringe — the photograph's lens flare, once.
  private static func glint(_ context: inout GraphicsContext, size: CGSize, progress: Double) {
    let alpha = Metrics.opacityGlint * (1 - progress)
    let x = size.width * progress
    let arm = size.height * Metrics.grilleGlintArm
    let width = Metrics.grilleGlintWidth
    let midY = size.height / 2
    func line(_ from: CGPoint, _ to: CGPoint, colour: Color, opacity: Double) {
      var path = Path()
      path.move(to: from)
      path.addLine(to: to)
      context.stroke(path, with: .color(colour.opacity(opacity)), lineWidth: width)
    }
    let fringe = alpha * 0.4  // literal-ok: the fringe is a fraction of the flare
    line(
      CGPoint(x: x + width, y: midY - arm / 2), CGPoint(x: x + width, y: midY + arm / 2),
      colour: DesignTokens.Brand.violetIris, opacity: fringe)
    line(
      CGPoint(x: x - width, y: midY - arm / 2), CGPoint(x: x - width, y: midY + arm / 2),
      colour: DesignTokens.Brand.green400, opacity: fringe)
    line(
      CGPoint(x: x, y: midY - arm / 2), CGPoint(x: x, y: midY + arm / 2), colour: DesignTokens.Brand.white,
      opacity: alpha)
    line(
      CGPoint(x: 0, y: midY), CGPoint(x: size.width, y: midY), colour: DesignTokens.Brand.white, opacity: alpha * 0.7)  // literal-ok: the horizontal arm sits back
    let core = Metrics.grilleDot * 2  // literal-ok: the flare's centre is a double dot
    context.fill(
      Path(ellipseIn: CGRect(x: x - core / 2, y: midY - core / 2, width: core, height: core)),  // literal-ok: centred
      with: .color(DesignTokens.Brand.white.opacity(alpha)))
  }
}
