import BlurtDesign
import SwiftUI

/// One style, as a chip: filled with the accent while active.
struct StyleChip: View {
  let name: String
  let selected: Bool
  let activate: () -> Void

  var body: some View {
    Button(action: activate) {
      Text(name)
        .font(BlurtType.body(DesignTokens.Typography.sizeCaption, bold: true))
        .padding(.horizontal, DesignTokens.Metrics.appChipPadX)
        .padding(.vertical, DesignTokens.Metrics.appChipPadY)
        .foregroundStyle(selected ? BlurtBrand.ctaText : BlurtBrand.text)
        .background(
          selected ? BlurtBrand.cta : BlurtBrand.cardFill,
          in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
        )
        .overlay(
          RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
            .strokeBorder(selected ? Color.clear : BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder)
        )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
