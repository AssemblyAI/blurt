import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// Picks the layout the user chose. All three share the voice bar and the
/// mic control, `KeyCap`, and the same model underneath; they differ in how
/// much keyboard surrounds the mic. The surface is the face's, fixed whatever
/// the host app's appearance — the keyboard floats over whichever app the
/// user is typing in, like the Mac pill — at the profile's spacing: the
/// iPhone keyboard's own for this OS generation and width
/// (`KeyboardProfile`, built once per appearance by the controller).
struct KeyboardRootView: View {
  var model: KeyboardModel
  let profile: KeyboardProfile

  var body: some View {
    let palette = model.palette(for: profile)
    Group {
      switch model.layout {
      case .panel: PanelCarousel(model: model, reduceMotion: reduceMotion)
      case .full: FullKeyboardView(model: model)
      case .slimBar:
        // The keys come up for a key term; the bar is back when it closes.
        if model.termDraft == nil { SlimBarView(model: model) } else { FullKeyboardView(model: model) }
      }
    }
    // The carousel's pages carry the side margin themselves, so a page is
    // the keyboard's full width and slides in flush with its edges.
    .padding(.horizontal, model.layout == .panel ? 0 : profile.marginSide)
    .padding(.top, profile.marginTop)
    .padding(.bottom, model.effectiveLayout == .slimBar ? profile.marginTop : profile.bottomInset)
    // Anchored to the bottom: if the host ever gives the keyboard more
    // height than its layout, the extra is surface above the keys, never
    // a hole under them.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    // iOS 26 wraps a third-party keyboard in the host's own rounded material,
    // inset above and below, and nothing the keyboard draws reaches the
    // inset: a painted surface shows a band of the host's grey above it. So
    // inside a container the surface is clear by default — the host's
    // material is the surface, seamlessly — and the keys take the colours
    // that read on it; the face is painted, grain on top, only when
    // `surface/paint` says so. Outside one (the classic generation) there is
    // no band to show, so the face's surface is painted under the keys.
    .background {
      if profile.paintsSurface { SurfaceFinish.Ground(surface: palette.surface) }
    }
    .overlay {
      if profile.paintsSurface { SurfaceFinish.Grain() }
    }
    .clipped()
    .environment(\.keyboardPalette, palette)
    .environment(\.keyboardInContainer, profile.inContainer)
    .environment(\.keyboardProfile, profile)
    .environment(\.voiceElementKind, model.voiceKind)
    // The carousel's swipe is not a SwiftUI gesture here. The surface is
    // clear, and the host hands the keyboard only the touches that land on
    // painted pixels: `KeyboardViewController` paints a floor the eye can't
    // see and recognises the swipe on the input view itself, which sees
    // every touch the keyboard gets, the panel's empty space included.
    // The slide itself is `PanelCarousel`'s.
  }

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.keyboardMotionHeld) private var motionHeld
  private var reduceMotion: Bool { systemReduceMotion || motionHeld }
}
