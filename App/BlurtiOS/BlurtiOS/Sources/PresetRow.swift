import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// A preset: its icon, name and a line of what it does; tap to add it.
struct PresetRow: View {
  let preset: StylePreset
  let isAdded: Bool
  let isFull: Bool
  let add: () -> Void

  var body: some View {
    Button(action: add) {
      HStack(spacing: DesignTokens.Metrics.appStackGap) {
        Image(systemName: preset.symbol)
          .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
          .foregroundStyle(BlurtBrand.accent)
          .frame(width: DesignTokens.Metrics.appIcon)
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
          Text(preset.name).foregroundStyle(BlurtBrand.text)
          Text(preset.instructions).font(BlurtType.body(DesignTokens.Typography.sizeCaption))
            .foregroundStyle(BlurtBrand.muted)
            .lineLimit(1)  // literal-ok: a line of the preset's instructions
        }
        Spacer()
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
  }
}
