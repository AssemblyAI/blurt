import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// One ordinary key: a glyph (SF Symbols, as the system keyboard's) or a
/// word (the brand's mono eyebrow) on a cap in the current face; `dark` for
/// the modifier keys, a step darker as on the system keyboard; `bare` for a
/// glyph with no cap at all. `flexible` keys (the space bar) take the width
/// they're given, `width` fixes one — the layouts pass `KeyGeometry`'s, so
/// a key is the same size on every page — and a key with neither is at least
/// the iPhone's 123 key wide, its legend padded inside that. `height` fixes
/// the cap's height where a row is not the standard 43 (the slim bar).
struct KeyCap: View {
  var title: String?
  var systemImage: String?
  var tint: Color?
  var flexible = false
  var dark = false
  var bare = false
  var width: CGFloat?
  var height: CGFloat?
  var action: () -> Void
  @Environment(\.keyboardPalette) private var palette
  @Environment(\.keyboardInContainer) private var inContainer

  static let height = DesignTokens.Metrics.keyHeight

  init(
    title: String? = nil, systemImage: String? = nil, tint: Color? = nil, flexible: Bool = false,
    dark: Bool = false, bare: Bool = false, width: CGFloat? = nil, height: CGFloat? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.flexible = flexible
    self.dark = dark
    self.bare = bare
    self.width = width
    self.height = height
    self.action = action
  }

  var body: some View {
    Group {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: DesignTokens.Typography.sizeLegend, weight: DesignTokens.Typography.weightLegend))
          .foregroundStyle(tint ?? palette.keyText)
      } else {
        // A word on a key — 123, ABC, #+=, space, the return label — is the
        // brand's eyebrow: the system mono, uppercase, tracked, a step
        // quieter than a letter. Tracking adds its space after the last
        // letter too; the same again before the first keeps the word centred.
        Text((title ?? "").uppercased())
          .font(BlurtType.mono(DesignTokens.Typography.sizeLabel, weight: DesignTokens.Typography.weightLabel))
          .tracking(DesignTokens.Typography.trackingEyebrow)
          .padding(.leading, DesignTokens.Typography.trackingEyebrow)
          .foregroundStyle(tint ?? palette.keyTextSecondary)
      }
    }
    .opacity(DesignTokens.Metrics.opacityLegend)
    // The padding sits inside the minimum width, so a glyph key is exactly
    // the minimum and only a long word widens a key past it.
    .padding(.horizontal, flexible || width != nil ? 0 : DesignTokens.Metrics.keyPad)
    .frame(maxWidth: flexible ? .infinity : nil)
    .frame(width: width, height: height)
    .frame(minWidth: width == nil ? DesignTokens.Metrics.keyMinWidth : nil, minHeight: height ?? Self.height)
    .keyCap(bare ? .clear : palette.keyFill(modifier: dark, inContainer: inContainer))
    .keyPress(action)
    .accessibilityLabel(title ?? systemImage ?? "")
  }
}

extension View {
  /// The cap under a key's legend: the palette's fill at the corner radius and
  /// nothing else — flat. No drop, no edge, no gloss.
  func keyCap(_ fill: Color) -> some View {
    background(fill, in: RoundedRectangle(cornerRadius: KeyboardPalette.keyRadius))
  }

  /// A key's touch: lights while the finger is down, acts on release — and
  /// only if the finger ended on the key, so a swipe across a key (the
  /// panel's carousel) never types while a thumb that rolls still does. The
  /// system keyboard's own rule (`KeyboardInteraction.isTap`).
  func keyPress(_ action: @escaping () -> Void) -> some View {
    modifier(KeyPress(action: action))
  }
}

struct KeyPress: ViewModifier {
  let action: () -> Void
  /// A gesture state: a touch the system takes away (a swipe from the screen's
  /// bottom edge, a call, the keyboard dismissed) unlights the key too, where
  /// a plain state would leave it lit.
  @GestureState private var pressed = false
  @State private var size = CGSize.zero

  func body(content: Content) -> some View {
    content
      .brightness(pressed ? DesignTokens.Metrics.opacityPressBrighten : 0)
      .animation(.easeOut(duration: DesignTokens.Motion.keyPress), value: pressed)
      .contentShape(Rectangle())
      .onGeometryChange(for: CGSize.self) {
        $0.size
      } action: {
        size = $0
      }
      .accessibilityAddTraits(.isButton)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .updating($pressed) { _, state, _ in state = true }
          .onEnded { value in
            guard KeyboardInteraction.isTap(value.translation, endedAt: value.location, in: size) else { return }
            action()
          }
      )
  }
}

/// A key lightens while the finger is on it, the way the system's change
/// shade, instead of the default button dimming.
struct KeyPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .brightness(configuration.isPressed ? DesignTokens.Metrics.opacityPressBrighten : 0)
      .animation(.easeOut(duration: DesignTokens.Motion.keyPress), value: configuration.isPressed)
  }
}
