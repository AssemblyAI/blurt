import BlurtDesign
import BlurtEngine
import SwiftUI

struct ShortcutRow: View {
  let shortcut: TextShortcut
  let remove: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Metrics.appStackGap) {
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
        Eyebrow(shortcut.trigger, color: BlurtBrand.accent)
        Text(shortcut.expansion)
          .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
          .foregroundStyle(BlurtBrand.text)
          .lineLimit(2)  // literal-ok: two lines of the replacement
      }
      Spacer(minLength: 0)
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: DesignTokens.Typography.sizeRemoveGlyph, weight: .semibold))
          .foregroundStyle(BlurtBrand.muted)
          .frame(width: DesignTokens.Metrics.appRowRemove, height: DesignTokens.Metrics.appRowRemove)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(shortcut.trigger)")
    }
    .padding(.vertical, DesignTokens.Metrics.appRowPadY)
  }
}
