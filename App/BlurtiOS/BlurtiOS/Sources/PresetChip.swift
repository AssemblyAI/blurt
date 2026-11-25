import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// A preset as a chip in the editor: its icon and name, filled with the accent
/// while the fields hold its text.
struct PresetChip: View {
  let preset: StylePreset
  let isChosen: Bool
  let choose: () -> Void

  var body: some View {
    Button(action: choose) {
      HStack(spacing: DesignTokens.Metrics.appLineGap) {
        // Decoration: the name beside it labels the chip.
        Image(systemName: preset.symbol).accessibilityHidden(true)
        Text(preset.name).lineLimit(1)
      }
      .font(BlurtType.body(DesignTokens.Typography.sizeCaption, bold: true))
      .padding(.vertical, DesignTokens.Metrics.appChipPadY)
      .frame(maxWidth: .infinity)
      .foregroundStyle(isChosen ? BlurtBrand.ctaText : BlurtBrand.text)
      .background(
        isChosen ? BlurtBrand.cta : BlurtBrand.cardFill,
        in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.radiusButton)
          .strokeBorder(BlurtBrand.cardBorder, lineWidth: DesignTokens.Metrics.cardBorder)
      )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isChosen ? .isSelected : [])
  }
}
