import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// A preset: its icon, name and a line of what it does; tap to add it.
struct PresetRow: View {
  let preset: StylePreset
  let isAdded: Bool
  let isFull: Bool
  let add: () -> Void
  @Environment(\.dynamicTypeSize)
  private var dynamicTypeSize

  var body: some View {
    // Icon, words and Add across the row; at an accessibility text size,
    // where that leaves the words a few letters a line, one over the other.
    let row =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap))
      : AnyLayout(HStackLayout(spacing: DesignTokens.Metrics.appStackGap))
    Button(action: add) {
      row {
        Image(systemName: preset.symbol)
          .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
          .foregroundStyle(BlurtBrand.accent)
          .frame(width: DesignTokens.Metrics.appIcon)
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
          Text(preset.name).foregroundStyle(BlurtBrand.text)
          Text(preset.instructions).bodyFont(DesignTokens.Typography.sizeCaption)
            .foregroundStyle(BlurtBrand.muted)
            // A line of the preset's instructions; all of them at an
            // accessibility text size, where a line is a few words.
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)  // literal-ok: one line
        }
        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
        if isAdded {
          Label("Added", systemImage: "checkmark").labelStyle(.iconOnly).foregroundStyle(BlurtBrand.accent)
        } else {
          Eyebrow("Add", color: BlurtBrand.accent)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isAdded && isFull)
    .accessibilityLabel(isAdded ? "\(preset.name), added" : "Add \(preset.name)")
    // The label names the action; what the preset does follows it.
    .accessibilityHint(preset.instructions)
  }
}
