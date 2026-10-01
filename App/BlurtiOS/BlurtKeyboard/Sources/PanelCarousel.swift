import SwiftUI

/// The panel's two pages — the mic panel and the full keyboard — as a strip
/// the finger slides, one page wide. The page that is up sits in the middle;
/// when a flip comes, the other page is set down a whole page away on the
/// side the finger moved towards, and the strip slides one page: the first
/// leaves one way as the second arrives the other. Side by side, a page
/// apart, the two can never cross, whichever way the flips come — left then
/// right, or left twice. A flip back before the slide has settled retreats
/// rather than starting a second slide over the first. `PanelCarouselState`
/// holds the rules (tested); this view only animates what it says.
struct PanelCarousel: View {
  var model: KeyboardModel
  let reduceMotion: Bool
  @State private var carousel: PanelCarouselState
  /// How far the strip has slid, in pages: 0 at rest, −1 or 1 at the end of
  /// a slide. The only animated value.
  @State private var slide: CGFloat = 0
  @State private var onScreen = false

  init(model: KeyboardModel, reduceMotion: Bool) {
    self.model = model
    self.reduceMotion = reduceMotion
    _carousel = State(initialValue: PanelCarouselState(keysUp: model.panelShowsKeys))
  }

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      ZStack(alignment: .bottom) {
        // The keys come up for a key term whichever page is up, in place.
        page(keys: carousel.keysUp || model.termDraft != nil, width: width)
          .offset(x: slide * width)
        if let edge = carousel.incomingEdge, model.termDraft == nil {
          page(keys: !carousel.keysUp, width: width)
            .offset(x: (slide + (edge == .trailing ? 1 : -1)) * width)
        }
      }
      .frame(width: width, height: geo.size.height, alignment: .bottom)
    }
    .onAppear { onScreen = true }
    .onDisappear { onScreen = false }
    .onChange(of: model.panelShowsKeys) { _, keysUp in flip(to: keysUp) }
  }

  /// One page at its own height, so neither is stretched while the keyboard
  /// is resizing under the slide.
  @ViewBuilder private func page(keys: Bool, width: CGFloat) -> some View {
    let height =
      (keys ? KeyboardLayout.full : .panel).height - KeyboardRootView.verticalMargin
      - KeyboardRootView.bottomMarginKeys
    if keys {
      FullKeyboardView(model: model).id("keys").frame(width: width, height: height, alignment: .bottom)
    } else {
      PanelView(model: model).id("panel").frame(width: width, height: height, alignment: .bottom)
    }
  }

  private func flip(to keysUp: Bool) {
    let motion = carousel.flip(
      to: keysUp, towardsLeading: model.flipTowardsLeading, animated: !reduceMotion && onScreen)
    guard let motion else {
      slide = 0
      return
    }
    withAnimation(.easeInOut(duration: DesignTokens.Motion.flip)) {
      slide = motion.slide
    } completion: {
      // Only the slide that was last asked for settles the strip; an older
      // one was overtaken and its ending means nothing.
      guard carousel.settle(motion.generation) else { return }
      var settled = Transaction()
      settled.disablesAnimations = true
      withTransaction(settled) { slide = 0 }
    }
  }
}

/// The carousel's rules, out of the view: which page is at rest in the
/// middle, which the model wants, where the other page waits, and which slide
/// is the current one — so a flip back mid-slide retreats, a retreat cut
/// short keeps its side, and a slide that was overtaken cannot settle the
/// strip late.
nonisolated struct PanelCarouselState: Equatable {
  enum Edge: Equatable {
    case leading
    case trailing
  }

  /// What the view animates: the strip's slide in pages, and the generation
  /// that may settle it when the slide ends.
  struct Motion: Equatable {
    let slide: CGFloat
    let generation: Int
  }

  /// The page in the middle at rest (true: the keys).
  private(set) var keysUp: Bool
  /// The page the model wants — the same as `keysUp` unless a slide is in flight.
  private(set) var target: Bool
  /// The side the other page waits on while a slide is in flight.
  private(set) var incomingEdge: Edge?
  private(set) var generation = 0

  var inFlight: Bool { incomingEdge != nil }

  init(keysUp: Bool) {
    self.keysUp = keysUp
    target = keysUp
  }

  /// The model flipped to `page`. Nil: settled at once, nothing to animate.
  /// Otherwise what `slide` animates to: a page away towards the finger, or
  /// back to 0 when this flip undoes one still in flight.
  mutating func flip(to page: Bool, towardsLeading: Bool, animated: Bool) -> Motion? {
    target = page
    generation += 1
    guard animated else {
      keysUp = page
      incomingEdge = nil
      return nil
    }
    guard page != keysUp else {
      // Flipped back before the slide settled: the incoming page retreats.
      return inFlight ? Motion(slide: 0, generation: generation) : nil
    }
    // A retreat cut short keeps its side; otherwise the finger's.
    let edge = incomingEdge ?? (towardsLeading ? Edge.trailing : .leading)
    incomingEdge = edge
    return Motion(slide: edge == .trailing ? -1 : 1, generation: generation)
  }

  /// A slide ended. True, and the strip is settled on the target page, only
  /// for the generation last asked for.
  mutating func settle(_ generation: Int) -> Bool {
    guard generation == self.generation else { return false }
    keysUp = target
    incomingEdge = nil
    return true
  }
}
