import BlurtEngine
import SwiftUI

/// The shared type, tracking, and color for the overlay's status-line text
/// ("Transcribing", "Pasted", "Copied", "Error") so they can't drift out of
/// sync.
///
/// Set in tracked uppercase, as the design draws it — the caps and the letter
/// spacing are what make a bare word read as a status readout rather than as a
/// sentence that lost its ending. The call sites pass ordinary capitalisation
/// and `textCase` does the shouting, so the strings stay readable in source and
/// the engine's accessibility labels (which speak the same states) aren't
/// dragged into all-caps.
struct StatusLineText: View {
  /// The status-line type, named so `OverlayWindowController.pillWidth(for:)`
  /// measures a written-out notice with exactly what draws it.
  static let fontSize: CGFloat = 9
  static let tracking: CGFloat = 0.9

  let text: String
  /// The text color — brand green for every state but `.error`, which the
  /// design gives its own orange rather than a red pill body.
  var color: Color = BlurtBrand.greenOnDark
  /// Where an over-long line is cut. The tail, except for a device name, which
  /// keeps its distinguishing end ("…Scarlett Solo USB").
  var truncation: Text.TruncationMode = .tail
  /// Whether an over-long line shrinks before it truncates. Fine for a status
  /// word; a sentence shrunk to 70% of 9 pt is unreadable, so a written-out
  /// notice truncates at full size instead.
  var shrinksToFit = true

  var body: some View {
    Text(text)
      .font(.system(size: Self.fontSize, weight: .semibold))
      .textCase(.uppercase)
      .tracking(Self.tracking)
      .lineLimit(1)
      .truncationMode(truncation)
      .minimumScaleFactor(shrinksToFit ? 0.7 : 1)
      .foregroundStyle(color)
  }

  init(
    _ text: String,
    color: Color = BlurtBrand.greenOnDark,
    truncation: Text.TruncationMode = .tail,
    shrinksToFit: Bool = true
  ) {
    self.text = text
    self.color = color
    self.truncation = truncation
    self.shrinksToFit = shrinksToFit
  }
}

/// Redraw cap for the pill's continuous animations — the brand orb's ring sweep
/// (`BrandOrb`, which is why this isn't file-private) and the waveform's idle
/// wave.
///
/// Read from the engine rather than restated: the cap exists *because* of the mic
/// meter's cadence (the level feed and these slow sines can't show anything
/// faster, so rendering at the display's full refresh rate — up to 120 Hz on
/// ProMotion — would only burn energy), so it tracks that one number instead of
/// duplicating it behind a comment that could go stale.
let overlayAnimationInterval = MicCapture.meterIntervalSeconds

extension View {
  /// Raised-cosine opacity breathing over `period`: 1 → `minOpacity` → 1, so the
  /// view eases through the dim point instead of bouncing off it. With
  /// `animated` false (Reduce Motion) the view renders untouched.
  ///
  /// Lives here rather than beside its one remaining caller (`ReadyView`'s
  /// Listening glyph) because it's the overlay's breathing curve — the pill's
  /// own uses moved to the orb's ring sweep, and the main window borrows the
  /// cadence deliberately so the two windows' motion matches.
  @ViewBuilder
  func pulsingOpacity(period: Double, minOpacity: Double, animated: Bool) -> some View {
    if animated {
      TimelineView(.animation(minimumInterval: overlayAnimationInterval)) { timeline in
        self.opacity(
          MeterBarGeometry.breathingOpacity(
            time: timeline.date.timeIntervalSinceReferenceDate,
            period: period,
            minOpacity: minOpacity
          )
        )
      }
    } else {
      self
    }
  }
}
