import BlurtEngine
import SwiftUI

/// The overlay pill's brand orb: a gradient disc that stands where the "● REC"
/// tag used to, present through every working state so the pill has one fixed
/// anchor while its right-hand side changes (bars → label). It replaces the
/// pulsing dot outright — a second blinking cue beside the meter would be noise.
///
/// A hairline ring **rotates** around the disc the whole time the orb is on
/// screen: connecting, recording, and transcribing alike. The orb is one object,
/// so it behaves like one — a ring that stopped during recording and restarted
/// on the hand-off to transcribing would read as two different orbs trading
/// places, which is exactly what keeping the disc fixed is meant to avoid. It
/// spins rather than breathes because a pulse says "alive" while a sweep says
/// "working, and still going". The disc underneath never moves.
struct BrandOrb: View {
  /// Whether to run the rotation (off under Reduce Motion, where the ring is
  /// still drawn — it's part of the mark, not decoration — but holds still).
  let animated: Bool

  /// One turn every 1.6 s: slow enough to read as deliberate rather than a
  /// spinner thrashing, quick enough that a sub-second wait still visibly moves.
  private let period: Double = 1.6

  /// Sized off the pill's height rather than stated absolutely, so the orb keeps
  /// the design's disc-to-pill ratio (24 pt in a 40 pt capsule) if the pill is
  /// ever resized. The ring is drawn *inside* the disc's bounds
  /// (`strokeBorder`), so this is the outer diameter of both.
  static let diameter = OverlayWindowController.pillSize.height * (24.0 / 40.0)

  var body: some View {
    Circle()
      .fill(BlurtBrand.orbGradient)
      .frame(width: Self.diameter, height: Self.diameter)
      .overlay { ring }
      // The orb is brand furniture; the pill as a whole already carries the
      // state's accessibility label (see `OverlayView`).
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var ring: some View {
    if animated {
      // Same continuous-clock pattern as the meter and the breathing label — the
      // angle is a pure function of the wall clock, so the sweep can't drift or
      // depend on a one-shot `repeatForever` that a state change would restart
      // mid-turn. Capped at the pill's shared redraw interval.
      TimelineView(.animation(minimumInterval: overlayAnimationInterval)) { timeline in
        ringShape
          .rotationEffect(
            .degrees(
              MeterBarGeometry.rotationDegrees(
                time: timeline.date.timeIntervalSinceReferenceDate, period: period)))
      }
    } else {
      ringShape
    }
  }

  /// `strokeBorder`, not `stroke`: it insets by half the line width, so the ring
  /// sits flush inside the disc instead of straddling its edge and fringing the
  /// gradient by half a point on every side.
  private var ringShape: some View {
    Circle().strokeBorder(BlurtBrand.orbRingGradient, lineWidth: 1)
  }
}
