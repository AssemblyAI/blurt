import SwiftUI

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
      .monoFont(DesignTokens.Typography.sizeCta, weight: .medium)
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
            role == .secondary ? BlurtBrand.cardBorder : Color.clear, lineWidth: DesignTokens.Metrics.cardBorder
          )
      )
      .opacity(configuration.isPressed ? DesignTokens.Metrics.opacityPressed : 1)
      .modifier(FadedWhenDisabled())
      .animation(.easeInOut(duration: DesignTokens.Motion.colour), value: configuration.isPressed)
  }
}
