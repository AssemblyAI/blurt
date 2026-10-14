import SwiftUI
import UIKit

/// The app's chrome, on the brand: the appearance-adaptive colours from the
/// asset catalog (generated from the tokens — page, text, muted, the card,
/// the one green button), the card, the eyebrow, the button, the wordmark.
/// The keyboard never uses these: it has its own faces.
extension BlurtBrand {
  /// `green` in light, the lifted green in dark — the catalog's `AccentColor`,
  /// also the app-level accent (`project.yml`).
  nonisolated static let accent = Color.accentColor
  /// The page: the design system's warm off-white in light, ink in dark.
  nonisolated static let page = Color("Page")
  nonisolated static let text = Color("Text")
  /// Eyebrows, captions, secondary lines.
  nonisolated static let muted = Color("Muted")
  /// The card: warm tint on paper, a step up from ink in dark, with a hairline.
  nonisolated static let cardFill = Color("CardFill")
  nonisolated static let cardBorder = Color("CardBorder")
  /// The one green button per row, and its text.
  nonisolated static let cta = Color("CTA")
  nonisolated static let ctaText = Color("CTAText")
}

extension View {
  /// The brand's card: the warm fill, 12 pt corners, a 1 pt hairline, no shadow.
  func card(radius: CGFloat = DesignTokens.Metrics.cardRadius) -> some View {
    background(BlurtBrand.cardFill, in: RoundedRectangle(cornerRadius: radius))
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(
          BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder))
  }

  /// The page under a screen: the ground colour with the brand's film grain over it.
  func page() -> some View {
    background {
      ZStack {
        BlurtBrand.page
        BlurtiOSGrain(seed: 7)
          .opacity(DesignTokens.Metrics.opacityGrainDark)
          .blendMode(.overlay)
          .allowsHitTesting(false)
      }
      .ignoresSafeArea()
    }
  }
}

extension View {
  /// A form or list on the brand: the page under it, the card as each row's
  /// ground, the body face for its text, the accent for its controls.
  func brandForm() -> some View {
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
struct Eyebrow: View {
  let text: String
  var color = BlurtBrand.muted

  init(_ text: String, color: Color = BlurtBrand.muted) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text.uppercased())
      .font(BlurtType.mono(DesignTokens.Typography.sizeEyebrow, weight: .medium))
      .tracking(DesignTokens.Typography.trackingEyebrow)
      .foregroundStyle(color)
  }
}

/// The brand's button: 40 pt, 4 pt corners — rectangular, never a pill —
/// its label in uppercase mono; a colour change while pressed, no lift.
/// `primary` is the one green button per row; `secondary` a hairline.
struct BrandButtonStyle: ButtonStyle {
  enum Role {
    case primary
    case secondary
  }

  var role = Role.primary

  func makeBody(configuration: Configuration) -> some View {
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
      .animation(.easeInOut(duration: DesignTokens.Motion.colour), value: configuration.isPressed)
  }
}

/// The lowercase wordmark from the Mac's ready screen, tinted with the accent
/// (`blurt-ready-logo.png`, shared from `Design/brand`).
struct Wordmark: View {
  private static let height = DesignTokens.Metrics.wordmarkHeight

  var body: some View {
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
