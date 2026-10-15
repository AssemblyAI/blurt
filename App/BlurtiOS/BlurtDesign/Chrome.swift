import SwiftUI
import UIKit

/// The app's chrome, on the brand: the card, the page, the form, the eyebrow,
/// the button, the wordmark. Screens are built from these rather than stock
/// `Form`/`List` styling or default buttons. The keyboard draws its own faces
/// (`KeyboardPalette`) and uses only the grain from here.
extension View {
  /// The brand's card: the warm fill, 12 pt corners, a 1 pt hairline, no shadow.
  package func card(radius: CGFloat = DesignTokens.Metrics.cardRadius) -> some View {
    background(BlurtBrand.cardFill, in: RoundedRectangle(cornerRadius: radius))
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(
          BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder))
  }

  /// The page under a screen: the ground colour with the brand's film grain over it.
  package func page() -> some View {
    background {
      ZStack {
        BlurtBrand.page
        FilmGrain(seed: 7)
          .opacity(DesignTokens.Metrics.opacityGrainDark)
          .blendMode(.overlay)
          .allowsHitTesting(false)
      }
      .ignoresSafeArea()
    }
  }

  /// A form or list on the brand: the page under it, the card as each row's
  /// ground, the body face for its text, the accent for its controls.
  package func brandForm() -> some View {
    scrollContentBackground(.hidden)
      .page()
      .listRowBackground(BlurtBrand.cardFill)
      .font(BlurtType.body(DesignTokens.Typography.sizeBody))
      .foregroundStyle(BlurtBrand.text)
      .tint(BlurtBrand.accent)
  }
}

/// An eyebrow: the system mono, uppercase, tracked, muted — the brand's
/// section label, above every group on a screen.
package struct Eyebrow: View {
  let text: String
  var color = BlurtBrand.muted

  package init(_ text: String, color: Color = BlurtBrand.muted) {
    self.text = text
    self.color = color
  }

  package var body: some View {
    Text(text.uppercased())
      .font(BlurtType.mono(DesignTokens.Typography.sizeEyebrow, weight: .medium))
      .tracking(DesignTokens.Typography.trackingEyebrow)
      .foregroundStyle(color)
  }
}

/// The brand's button: 40 pt, 4 pt corners — rectangular, never a pill —
/// its label in uppercase mono; a colour change while pressed, no lift.
/// `primary` is the one accent button per row; `secondary` a hairline.
package struct BrandButtonStyle: ButtonStyle {
  package enum Role {
    case primary
    case secondary
  }

  var role = Role.primary

  package init(role: Role = .primary) { self.role = role }

  package func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(BlurtType.mono(DesignTokens.Typography.sizeCta, weight: .medium))
      .tracking(DesignTokens.Typography.trackingCta)
      .textCase(.uppercase)
      .foregroundStyle(role == .primary ? BlurtBrand.ctaText : BlurtBrand.text)
      .padding(.horizontal, DesignTokens.Metrics.appButtonPad)
      .frame(maxWidth: .infinity, minHeight: DesignTokens.Metrics.appButtonHeight)
      .background(
        role == .primary ? BlurtBrand.cta : Color.clear,
        in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
          .strokeBorder(
            role == .secondary ? BlurtBrand.cardBorder : Color.clear, lineWidth: DesignTokens.Metrics.cardBorder)
      )
      .opacity(configuration.isPressed ? DesignTokens.Metrics.opacityPressed : 1)
      .modifier(FadedWhenDisabled())
      .animation(.easeInOut(duration: DesignTokens.Motion.colour), value: configuration.isPressed)
  }
}

/// A brand button that can't be pressed yet sits back rather than looking live.
/// A modifier because a `ButtonStyle` can't read the environment itself.
private struct FadedWhenDisabled: ViewModifier {
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    content.opacity(isEnabled ? 1 : DesignTokens.Metrics.opacityDisabled)
  }
}

extension View {
  /// The brand's input: the page colour inside the card, 8 pt corners, the
  /// card's hairline, the body face.
  package func brandInput() -> some View {
    font(BlurtType.body(DesignTokens.Typography.sizeBody))
      .foregroundStyle(BlurtBrand.text)
      .padding(.horizontal, DesignTokens.Metrics.appChipPadX)
      .padding(.vertical, DesignTokens.Metrics.appInputPadY)
      .background(BlurtBrand.page, in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusInput))
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusInput)
          .strokeBorder(BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder))
  }

  /// The brand's small print under a card: the caption size, muted.
  package func brandFootnote() -> some View {
    font(BlurtType.body(DesignTokens.Typography.sizeCaption))
      .foregroundStyle(BlurtBrand.muted)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// The lowercase wordmark from the Mac's ready screen, tinted with the accent.
/// The image (`blurt-ready-logo.png`, shared from `Design/brand`) is the host
/// bundle's resource, not the library's; without it the word is set in the
/// heading face instead.
package struct Wordmark: View {
  private static let height = DesignTokens.Metrics.wordmarkHeight

  package init() {}

  package var body: some View {
    if let image = UIImage(named: "blurt-ready-logo") {
      Image(uiImage: image)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(height: Self.height)
        .foregroundStyle(BlurtBrand.accent)
        .accessibilityLabel("Blurt")
    } else {
      Text("blurt")
        .font(BlurtType.heading(DesignTokens.Typography.sizeTitle))
        .foregroundStyle(BlurtBrand.accent)
    }
  }
}
