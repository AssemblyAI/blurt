import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// Blurt is on: the app-switcher card. `RootView` lays it over the app
/// whenever the scene leaves the front with a listening window on, so the card
/// iOS shows for Blurt — in the switcher, and the snapshot it keeps — says to
/// keep Blurt in the background and for how long it listens (`KeepOpen`).
/// Nothing on it is ever tapped: the scene is inactive whenever it shows.
/// Above the words, the screensaver, the old DVD player's, on a little screen
/// of its own — a hairline card the wordmark drifts across edge to edge
/// (`Bounce`), a new colour at every wall, and on an exact corner a cross
/// flare, a success haptic and one more on the tally. Reduce Motion parks the
/// wordmark in the middle.
struct KeepOpenView: View {
  let windowMinutes: Int
  /// Every motion held at time zero, for a capture (`-BlurtGalleryStill`).
  var still = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// When the card appeared: the bounce's time zero, so each trip to the
  /// switcher starts a fresh run with its first corner 9 s in.
  @State private var appeared = Date()
  /// The screen's inside, measured: the room the bounce has.
  @State private var stage = CGSize.zero

  private var moving: Bool { !reduceMotion && !still }

  private static let item = CGSize(
    width: DesignTokens.Metrics.keepOpenWordmarkHeight * Wordmark.aspectRatio,
    height: DesignTokens.Metrics.keepOpenWordmarkHeight)

  var body: some View {
    TimelineView(.animation(paused: !moving)) { context in
      let time = context.date.timeIntervalSince(appeared)
      let bounce = Bounce(
        stage: stage, item: Self.item, speed: DesignTokens.Metrics.keepOpenSpeed,
        firstCorner: DesignTokens.Motion.keepOpenFirstCorner, tolerance: DesignTokens.Metrics.keepOpenCornerTolerance)
      let frame = moving ? bounce.frame(at: time) : bounce.parked
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appHeroGap) {
        // The header's row, the tally in its trailing corner: the header's
        // height whether or not there is one, so the screen below has the
        // same room still or moving. No corners to count while the wordmark
        // stands still.
        HStack {
          Spacer()
          if moving { Eyebrow(KeepOpen.tally(frame.corners)) }
        }
        .frame(height: DesignTokens.Metrics.appHeaderHeight)
        saver(frame, bounce: bounce, time: time)
        words
      }
      .padding(.horizontal, DesignTokens.Metrics.appPagePad)
      // Only on a new corner: the tally starts over each time the card
      // appears, and that drop is not a corner.
      .sensoryFeedback(.success, trigger: frame.corners) { old, new in new > old }
    }
    .page()
    .accessibilityAddTraits(.isModal)
  }

  // MARK: - The screensaver

  /// The screen: the wordmark where the bounce has it, in the colour of the
  /// walls it has touched, and the flare over the last corner while it lasts,
  /// inside a hairline card at the brand's button corner — square enough that
  /// a corner is a corner.
  private func saver(_ frame: Bounce.Frame, bounce: Bounce, time: TimeInterval) -> some View {
    let tints = BlurtBrand.keepOpenTints
    return ZStack(alignment: .topLeading) {
      Wordmark(height: Self.item.height, tint: tints[frame.wallHits % tints.count])
        .animation(.easeInOut(duration: DesignTokens.Motion.colour), value: frame.wallHits)
        .offset(x: frame.origin.x, y: frame.origin.y)
        .accessibilityHidden(true)
      if let corner = frame.lastCorner {
        let progress = (time - corner.at) / DesignTokens.Motion.keepOpenFlare
        if progress >= 0, progress < 1 {
          Flare(progress: progress)
            .frame(width: Self.item.width, height: Self.item.height)
            .offset(
              x: corner.trailing ? bounce.travel.width : 0, y: corner.bottom ? bounce.travel.height : 0)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onGeometryChange(for: CGSize.self, of: \.size) { stage = $0 }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton))
    .card(radius: DesignTokens.Metrics.radiusButton)
  }

  // MARK: - The words

  private var words: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appHeroGap) {
      Eyebrow(KeepOpen.eyebrow, color: BlurtBrand.accent)
      Text(KeepOpen.headline)
        .font(BlurtType.heading(DesignTokens.Typography.sizeTitle))
        .foregroundStyle(BlurtBrand.text)
      Text(KeepOpen.body(windowMinutes: windowMinutes))
        .font(BlurtType.body(DesignTokens.Typography.sizeBody))
        .foregroundStyle(BlurtBrand.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, DesignTokens.Metrics.appSectionGap)
  }
}

/// The cross flare over the wordmark in a corner: the grille's landing glint
/// at the wordmark's scale — a thin cross in the text colour, its arms past
/// the wordmark, a green and a violet fringe either side of the upright (the
/// violets only ever as light), fading out as it lives.
private struct Flare: View {
  let progress: Double

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      let centre = CGPoint(x: size.width / 2, y: size.height / 2)  // literal-ok: the wordmark's centre
      let arm = size.height * DesignTokens.Metrics.keepOpenFlareArm / 2  // literal-ok: half above, half below
      let span = size.width * DesignTokens.Metrics.keepOpenFlareSpan / 2  // literal-ok: half each side
      let line = DesignTokens.Metrics.keepOpenFlareWidth
      let core = DesignTokens.Metrics.keepOpenFlareCore
      let alpha = DesignTokens.Metrics.opacityGlint * (1 - progress)
      let fringe = alpha * 0.4  // literal-ok: the fringe is a fraction of the flare, as the grille's
      ZStack {
        upright(centre, arm: arm, shift: line).stroke(DesignTokens.Brand.violetIris.opacity(fringe), lineWidth: line)
        upright(centre, arm: arm, shift: -line).stroke(DesignTokens.Brand.green400.opacity(fringe), lineWidth: line)
        upright(centre, arm: arm, shift: 0).stroke(BlurtBrand.text.opacity(alpha), lineWidth: line)
        Path { path in
          path.move(to: CGPoint(x: centre.x - span, y: centre.y))
          path.addLine(to: CGPoint(x: centre.x + span, y: centre.y))
        }
        // The horizontal arm sits back.
        .stroke(BlurtBrand.text.opacity(alpha * 0.7), lineWidth: line)  // literal-ok: as the grille's
        Circle()
          .fill(BlurtBrand.text.opacity(alpha))
          .frame(width: core, height: core)
          .position(centre)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func upright(_ centre: CGPoint, arm: CGFloat, shift: CGFloat) -> Path {
    Path { path in
      path.move(to: CGPoint(x: centre.x + shift, y: centre.y - arm))
      path.addLine(to: CGPoint(x: centre.x + shift, y: centre.y + arm))
    }
  }
}
