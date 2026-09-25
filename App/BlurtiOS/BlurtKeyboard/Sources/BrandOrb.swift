import BlurtEngine
import SwiftUI

/// The redraw cap for the keyboard's continuous motion — the perimeter's
/// sweep, the meter's idle wave. The Mac pill reads the same number from the
/// engine: the level feed moves at this cadence, so drawing faster only burns
/// the keyboard's tight energy and memory budget.
let keyboardAnimationInterval = MicCapture.meterIntervalSeconds

/// The brand orb as the phone draws it: a flat two-tone disc, and a soft
/// comet of the palette circling its perimeter — slowly at rest, so the orb
/// is never still, at the Mac pill's pace while the app works. The disc
/// underneath never moves. No glyph, no gloss, no shadow.
///
/// Sized by the caller: the app's home screen draws it as the hero, the
/// keyboard as the mic key.
struct BrandOrb: View {
  var diameter: CGFloat
  /// Seconds per turn of the perimeter.
  var period: Double = BrandOrb.restPeriod
  var ringWidth: CGFloat = 2
  /// A solid ring in place of the sweep — a notice's green or orange.
  var ringColor: Color?
  /// Whether the perimeter moves. Off under Reduce Motion, where the sweep is
  /// still drawn but holds still.
  var animated = true

  /// At rest: one slow turn every 4 s, alive but not busy.
  static let restPeriod: Double = 4
  /// While the app works: the Mac pill's 1.6 s.
  static let workingPeriod: Double = 1.6

  var body: some View {
    Circle()
      .fill(BlurtBrand.orbFlat)
      .frame(width: diameter, height: diameter)
      .overlay { ring }
      .accessibilityHidden(true)
  }

  @ViewBuilder private var ring: some View {
    if let ringColor {
      Circle().strokeBorder(ringColor, lineWidth: ringWidth)
    } else if animated {
      // The angle is a pure function of the clock (engine geometry), so the
      // sweep can't drift or restart mid-turn when the state beside it changes.
      TimelineView(.animation(minimumInterval: keyboardAnimationInterval)) { timeline in
        sweep.rotationEffect(
          .degrees(
            MeterBarGeometry.rotationDegrees(
              time: timeline.date.timeIntervalSinceReferenceDate, period: period)))
      }
    } else {
      sweep
    }
  }

  /// `strokeBorder` so the ring sits inside the disc instead of fringing it.
  private var sweep: some View {
    Circle().strokeBorder(BlurtBrand.orbSweep, lineWidth: ringWidth)
  }
}
