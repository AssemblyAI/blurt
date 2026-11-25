import SwiftUI

/// The app's chrome, on the brand: the card, the page, the form, the eyebrow,
/// the button, the wordmark. Screens are built from these rather than stock
/// `Form`/`List` styling or default buttons. The keyboard is KeyboardKit's and
/// takes nothing from here.
extension View {
  /// The brand's card: the warm fill, 12 pt corners, a 1 pt hairline, no shadow.
  package func card(radius: CGFloat = DesignTokens.Metrics.cardRadius) -> some View {
    background(BlurtBrand.cardFill, in: RoundedRectangle(cornerRadius: radius))
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(
          BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder
        )
      )
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
      .bodyFont(DesignTokens.Typography.sizeBody)
      .foregroundStyle(BlurtBrand.text)
      .tint(BlurtBrand.accent)
  }
}

extension View {
  /// The brand's input: the page colour inside the card, 8 pt corners, the
  /// card's hairline, the body face.
  package func brandInput() -> some View {
    bodyFont(DesignTokens.Typography.sizeBody)
      .foregroundStyle(BlurtBrand.text)
      .padding(.horizontal, DesignTokens.Metrics.appChipPadX)
      .padding(.vertical, DesignTokens.Metrics.appInputPadY)
      .background(BlurtBrand.page, in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusInput))
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusInput)
          .strokeBorder(BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder)
      )
  }

  /// The brand's small print under a card: the caption size, muted.
  package func brandFootnote() -> some View {
    bodyFont(DesignTokens.Typography.sizeCaption)
      .foregroundStyle(BlurtBrand.muted)
      .fixedSize(horizontal: false, vertical: true)
  }
}
