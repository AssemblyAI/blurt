import BlurtEngine
import SwiftUI

/// The redraw cap for the keyboard's continuous motion — the ring's sweep, the
/// meter's idle wave. The Mac pill reads the same number from the engine: the
/// level feed moves at this cadence, so drawing faster only burns the
/// keyboard's tight energy and memory budget.
let keyboardAnimationInterval = MicCapture.meterIntervalSeconds

/// The brand orb, as the Mac pill draws it (`App/Blurt/Blurt/Overlay/BrandOrb.swift`):
/// the gradient disc, and a hairline ring that sweeps round it while something
/// is happening. It spins rather than pulses — a pulse says "alive", a sweep
/// says "working, and still going" — and the disc underneath never moves.
///
/// Sized by the caller, because the keyboard draws it at two scales: inside
/// the status pill, and as the mic key itself.
struct BrandOrb: View {
  var diameter: CGFloat
  /// Whether the ring sweeps. Off under Reduce Motion, where the ring is still
  /// drawn — it is part of the mark — but holds still.
  var animated: Bool
  var ringWidth: CGFloat = 1

  /// One turn every 1.6 s: the Mac's cadence.
  static let period: Double = 1.6

  var body: some View {
    Circle()
      .fill(BlurtBrand.orbGradient)
      .frame(width: diameter, height: diameter)
      .overlay { ring }
      .accessibilityHidden(true)
  }

  @ViewBuilder private var ring: some View {
    if animated {
      // The angle is a pure function of the clock (engine geometry), so the
      // sweep can't drift or restart mid-turn when the state beside it changes.
      TimelineView(.animation(minimumInterval: keyboardAnimationInterval)) { timeline in
        ringShape.rotationEffect(
          .degrees(
            MeterBarGeometry.rotationDegrees(
              time: timeline.date.timeIntervalSinceReferenceDate, period: Self.period)))
      }
    } else {
      ringShape
    }
  }

  /// `strokeBorder` so the ring sits inside the disc instead of fringing it.
  private var ringShape: some View {
    Circle().strokeBorder(BlurtBrand.orbRingGradient, lineWidth: ringWidth)
  }
}

/// The pill's status word — "Transcribing", "Pasted", "Error" — in the Mac's
/// tracked uppercase, scaled from the pill's 9 pt to 11 pt for a phone held at
/// arm's length. Brand green, except the error word's orange.
struct StatusLineText: View {
  let text: String
  var color: Color = BlurtBrand.greenOnDark

  init(_ text: String, color: Color = BlurtBrand.greenOnDark) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .textCase(.uppercase)
      .tracking(1.1)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .foregroundStyle(color)
  }
}
