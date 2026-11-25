import BlurtDesign
import SwiftUI

/// A bare glyph as a key — the +, the × and the ✓ of the key-term bar — in a
/// square big enough for a finger.
struct GlyphKey: View {
  let symbol: String
  let tint: Color
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
        .foregroundStyle(tint)
        .frame(width: DesignTokens.Metrics.glyphHit, height: DesignTokens.Metrics.glyphHit)
        .contentShape(Rectangle())
    }
    .buttonStyle(KeyPressStyle())
    .accessibilityLabel(label)
  }
}
