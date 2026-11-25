import BlurtDesign
import BlurtEngine
import SwiftUI

/// A style: tap to use it; its pencil (a style of the user's own) edits it.
struct StyleRow: View {
  let name: String
  let detail: String
  let isActive: Bool
  let edit: (() -> Void)?
  let activate: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Metrics.appStackGap) {
      Button(action: activate) {
        HStack {
          VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
            Text(name).foregroundStyle(BlurtBrand.text)
            Text(detail)
              .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
              .foregroundStyle(BlurtBrand.muted)
              .lineLimit(2)  // literal-ok: two lines of instructions
          }
          Spacer()
          // Decoration: the button carries the active style as its selected trait.
          if isActive { Image(systemName: "checkmark").foregroundStyle(BlurtBrand.accent).accessibilityHidden(true) }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isActive ? .isSelected : [])
      if let edit {
        Button(action: edit) {
          Image(systemName: "pencil")
            .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
            .foregroundStyle(BlurtBrand.accent)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Edit \(name)")
      }
    }
  }
}
