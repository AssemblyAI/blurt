import SwiftUI

/// The small + beside the orb (and in the panel's corner): a new key term.
/// A bare glyph, quiet until it is needed; a check for a moment after one
/// was saved.
struct AddTermKey: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette

  var body: some View {
    Button {
      model.beginAddingTerm()
    } label: {
      Image(systemName: model.termSavedAt == nil ? "plus" : "checkmark")
        .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
        .foregroundStyle(
          model.termSavedAt == nil ? palette.keyText.opacity(DesignTokens.Metrics.opacityLegendMuted) : palette.signal
        )
        .frame(width: DesignTokens.Metrics.glyphHit, height: DesignTokens.Metrics.glyphHit)
        .contentShape(Circle())
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(KeyPressStyle())
    .accessibilityLabel("Add a key term")
    .disabled(!model.hasFullAccess)
    .opacity(model.hasFullAccess ? 1 : DesignTokens.Metrics.opacityDisabled)
  }
}
