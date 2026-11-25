import BlurtDesign
import BlurtiOSCore
import KeyboardKit
import SwiftUI

/// The bar as a field, in a key's own colours: × to leave, what has been
/// typed with a caret, ✓ to save. Return saves too. × and ✓ are the same
/// glyph keys as the +.
struct TermField: View {
  var model: BlurtiOSCore.KeyboardModel
  @EnvironmentObject private var keyboardContext: KeyboardContext

  var body: some View {
    let scheme = keyboardContext.colorScheme
    HStack(spacing: DesignTokens.Metrics.termGap) {
      GlyphKey(
        symbol: "xmark", tint: BlurtTint.legend(scheme).opacity(DesignTokens.Metrics.opacityTermCancel), label: "Cancel"
      ) {
        model.cancelAddingTerm()
      }
      HStack(spacing: 0) {
        if let draft = model.termDraft, !draft.isEmpty {
          Text(draft).foregroundStyle(BlurtTint.legend(scheme))
          Caret(gap: .leading)
        } else {
          Caret(gap: .trailing)
          Text("New key term")
            .foregroundStyle(BlurtTint.legend(scheme).opacity(DesignTokens.Metrics.opacityPlaceholder))
        }
        Spacer(minLength: 0)
      }
      .font(.system(size: DesignTokens.Typography.sizeTerm, weight: DesignTokens.Typography.weightTerm))
      .lineLimit(1)
      .padding(.horizontal, DesignTokens.Metrics.termPad)
      .frame(maxWidth: .infinity)
      .frame(height: DesignTokens.Metrics.termHeight)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.termRadius)
          .fill(BlurtTint.field(scheme))
          .strokeBorder(BlurtTint.edge(scheme), lineWidth: DesignTokens.Metrics.termBorder)
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Key term: \(model.termDraft ?? "")")
      GlyphKey(symbol: "checkmark", tint: BlurtTint.signal(scheme), label: "Save the key term") { model.saveTerm() }
        .disabled(model.termDraft?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }
    .padding(.horizontal, DesignTokens.Metrics.termInset)
  }
}
