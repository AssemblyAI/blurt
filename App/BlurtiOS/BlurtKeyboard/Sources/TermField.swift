import SwiftUI

/// The voice bar as a field — the brand's input, a rectangle with a hairline,
/// never a capsule: × to leave, what has been typed with a caret, ✓ to save.
/// Return saves too.
struct TermField: View {
  var model: KeyboardModel
  @Environment(\.keyboardPalette) private var palette

  var body: some View {
    HStack(spacing: DesignTokens.Metrics.termGap) {
      round("xmark", tint: palette.keyText.opacity(DesignTokens.Metrics.opacityTermCancel)) { model.cancelAddingTerm() }
        .accessibilityLabel("Cancel")
      HStack(spacing: 0) {
        if let draft = model.termDraft, !draft.isEmpty {
          Text(draft).foregroundStyle(palette.keyText)
        } else {
          Text("New key term").foregroundStyle(palette.keyText.opacity(DesignTokens.Metrics.opacityPlaceholder))
        }
        Caret()
        Spacer(minLength: 0)
      }
      .font(.system(size: DesignTokens.Typography.sizeTerm, weight: DesignTokens.Typography.weightTerm))
      .lineLimit(1)
      .padding(.horizontal, DesignTokens.Metrics.termPad)
      .frame(maxWidth: .infinity)
      .frame(height: DesignTokens.Metrics.termHeight)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Metrics.termRadius)
          .fill(palette.field)
          .strokeBorder(palette.fieldBorder, lineWidth: DesignTokens.Metrics.termBorder)
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Key term: \(model.termDraft ?? "")")
      round("checkmark", tint: palette.signal) { model.saveTerm() }
        .accessibilityLabel("Save the key term")
        .disabled(model.termDraft?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }
    .padding(.horizontal, DesignTokens.Metrics.termInset)
  }

  /// × and ✓: bare glyphs, as the + is.
  private func round(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
        .foregroundStyle(tint)
        .frame(width: DesignTokens.Metrics.glyphHit, height: DesignTokens.Metrics.glyphHit)
        .contentShape(Circle())
    }
    .buttonStyle(KeyPressStyle())
  }
}

/// A blinking caret, as a text field's; held on while motion is held.
private struct Caret: View {
  @Environment(\.keyboardPalette) private var palette
  @Environment(\.keyboardMotionHeld) private var motionHeld

  var body: some View {
    TimelineView(.periodic(from: .now, by: DesignTokens.Motion.caret)) { timeline in
      let on = motionHeld || Int(timeline.date.timeIntervalSinceReferenceDate / DesignTokens.Motion.caret) % 2 == 0
      RoundedRectangle(cornerRadius: DesignTokens.Metrics.caretRadius)
        .fill(palette.signal)
        .frame(width: DesignTokens.Metrics.caretWidth, height: DesignTokens.Metrics.caretHeight)
        .opacity(on ? 1 : 0)
        .padding(.leading, DesignTokens.Metrics.caretLead)
    }
    .accessibilityHidden(true)
  }
}
