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
  private static let item = CGSize(
    width: DesignTokens.Metrics.keepOpenWordmarkHeight * Wordmark.aspectRatio,
    height: DesignTokens.Metrics.keepOpenWordmarkHeight
  )

  let windowMinutes: Int
  /// Every motion held at time zero, for a capture (`-BlurtGalleryStill`).
  var still = false

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  /// When the card appeared: the bounce's time zero, so each trip to the
  /// switcher starts a fresh run with its first corner 9 s in.
  @State private var appeared = Date()
  /// The screen's inside, measured: the room the bounce has.
  @State private var stage = CGSize.zero

  private var moving: Bool { !reduceMotion && !still }

  var body: some View {
    TimelineView(.animation(paused: !moving)) { context in
      let time = context.date.timeIntervalSince(appeared)
      let bounce = Bounce(
        stage: stage,
        item: Self.item,
        speed: DesignTokens.Metrics.keepOpenSpeed,
        firstCorner: DesignTokens.Motion.keepOpenFirstCorner,
        tolerance: DesignTokens.Metrics.keepOpenCornerTolerance
      )
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

  // MARK: - The words

  private var words: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appHeroGap) {
      Eyebrow(KeepOpen.eyebrow, color: BlurtBrand.accent)
      Text(KeepOpen.headline)
        .headingFont(DesignTokens.Typography.sizeTitle)
        .foregroundStyle(BlurtBrand.text)
        // Wraps rather than truncating at a large text size, as the body does.
        .fixedSize(horizontal: false, vertical: true)
      Text(KeepOpen.body(windowMinutes: windowMinutes))
        .bodyFont(DesignTokens.Typography.sizeBody)
        .foregroundStyle(BlurtBrand.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, DesignTokens.Metrics.appSectionGap)
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
              x: corner.trailing ? bounce.travel.width : 0, y: corner.bottom ? bounce.travel.height : 0
            )
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onGeometryChange(for: CGSize.self, of: \.size) { stage = $0 }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton))
    .card(radius: DesignTokens.Metrics.radiusButton)
  }
}
