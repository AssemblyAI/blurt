import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// A preset as a chip in the editor: its icon and name, filled with the accent
/// while the fields hold its text.
struct PresetChip: View {
  let preset: StylePreset
  let isChosen: Bool
  let choose: () -> Void
  @Environment(\.dynamicTypeSize)
  private var dynamicTypeSize

  var body: some View {
    // The icon beside the name; over it at an accessibility text size, where
    // a one-word name ("Professional") needs the chip's whole width.
    let content =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: DesignTokens.Metrics.appLineGap))
      : AnyLayout(HStackLayout(spacing: DesignTokens.Metrics.appLineGap))
    Button(action: choose) {
      content {
        // Decoration: the name beside it labels the chip.
        Image(systemName: preset.symbol).accessibilityHidden(true)
        // One line across a third of the row; at an accessibility text size,
        // where each chip has the row to itself, as many as the name needs.
        Text(preset.name).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)  // literal-ok: one line
          .fixedSize(horizontal: false, vertical: true)
          // A one-word name can't wrap: past the chip's width it narrows a
          // little rather than losing its last letters.
          .minimumScaleFactor(0.8)  // literal-ok: a fifth smaller at most
      }
      .bodyFont(DesignTokens.Typography.sizeCaption, bold: true)
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
