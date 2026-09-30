import SwiftUI

/// Picks the layout the user chose. All three share the voice bar and the
/// mic control, `KeyCap`, and the same model underneath; they differ in how
/// much keyboard surrounds the mic. The surface is the face's, fixed whatever
/// the host app's appearance — the keyboard floats over whichever app the
/// user is typing in, like the Mac pill — at the iPhone keyboard's own
/// spacing.
struct KeyboardRootView: View {
  var model: KeyboardModel

  /// The keyboard's top margin (and the slim bar's bottom): the arithmetic in
  /// `KeyboardLayout.height` is built on it and the palette's row gap.
  static let verticalMargin = DesignTokens.Metrics.marginVertical
  /// Under a bottom row of keys, the iPhone's own margin.
  static let bottomMarginKeys = DesignTokens.Metrics.marginBottomKeys
  /// Whether the face's surface is painted under the keys (`surface/paint`).
  static let paintsSurface = DesignTokens.Metrics.surfacePaint > 0

  var body: some View {
    Group {
      switch model.effectiveLayout {
      case .slimBar: SlimBarView(model: model)
      case .panel:
        PanelView(model: model)
          .id("panel")
          .transition(flip)
      case .full:
        FullKeyboardView(model: model)
          .id(model.layout == .panel ? "panel-keys" : "full")
          .transition(flip)
      }
    }
    .padding(.horizontal, KeyboardPalette.margin)
    .padding(.top, Self.verticalMargin)
    .padding(.bottom, model.effectiveLayout == .slimBar ? Self.verticalMargin : Self.bottomMarginKeys)
    // Anchored to the bottom: if the host ever gives the keyboard more
    // height than its layout, the extra is surface above the keys, never
    // a hole under them.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    // iOS 26 wraps a third-party keyboard in the host's own rounded material,
    // inset above and below, and nothing the keyboard draws reaches the
    // inset: a painted surface shows a band of the host's grey above it. So
    // by default the surface is clear — the host's material is the surface,
    // seamlessly — and the keys take the colours that read on it; the face
    // is painted, grain on top, only when `surface/paint` says so.
    .background {
      if Self.paintsSurface { SurfaceFinish.Ground(surface: model.palette.surface) }
    }
    .overlay {
      if Self.paintsSurface { SurfaceFinish.Grain() }
    }
    .clipped()
    .environment(\.keyboardPalette, model.palette)
    .environment(\.keyboardInContainer, !Self.paintsSurface)
    .environment(\.voiceElementKind, model.voiceKind)
    .simultaneousGesture(swipe, including: model.layout == .panel ? .all : .subviews)
    .animation(reduceMotion ? nil : .easeInOut(duration: DesignTokens.Motion.flip), value: model.panelShowsKeys)
    .onAppear {
      // `Font.custom` falls back to the system font in silence; the bundle
      // must know the brand's faces (UIAppFonts + Design/fonts).
      assert(BlurtType.missing().isEmpty, "fonts not registered: \(BlurtType.missing())")
    }
  }

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.keyboardMotionHeld) private var motionHeld
  private var reduceMotion: Bool { systemReduceMotion || motionHeld }

  /// The carousel's slide: the incoming page arrives from the side the finger
  /// moved towards, the outgoing one leaves the other way.
  private var flip: AnyTransition {
    model.flipTowardsLeading
      ? .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
      : .asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
  }

  /// A horizontal swipe anywhere on the panel flips it; taps and holds on keys
  /// never travel this far, and the keys ignore a touch that did
  /// (`KeyboardInteraction`).
  private var swipe: some Gesture {
    DragGesture(minimumDistance: DesignTokens.Metrics.gestureSwipeMin)
      .onEnded { value in
        guard let direction = KeyboardInteraction.flip(value.translation) else { return }
        model.flipPanel(towardsLeading: direction == .towardsLeading)
      }
  }
}
