import SwiftUI

/// The small + beside the element (and in the panel's corner): a new key
/// term. A bare glyph, quiet until it is needed; a check for a moment after
/// one was saved.
///
/// Highlight a word in the text and the + is a chip instead — the field's
/// shape, holding the word — and one tap adds the word as it stands: + for a
/// word Blurt doesn't know yet, ✓ once it does. Holding the chip opens the
/// field pre-filled instead, to fix the spelling first (`KeyboardModel`:
/// `selectedTerm`, `addSelectedTerm`, `beginAddingTerm`).
struct AddTermKey: View {
  var model: KeyboardModel
  /// The most the chip may take, where nothing else bounds it (the panel's
  /// corner); nil where the row's own room does (the bar).
  var maxWidth: CGFloat?
  @Environment(\.keyboardPalette) private var palette
  @State private var pressed = false
  @State private var hold: Task<Void, Never>?
  @State private var held = false

  var body: some View {
    ZStack {
      if let term = model.selectedTerm {
        chip(term).transition(.opacity)
      } else {
        plain.transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: DesignTokens.Motion.stateFade), value: model.selectedTerm == nil)
    .disabled(!model.hasFullAccess)
    .opacity(model.hasFullAccess ? 1 : DesignTokens.Metrics.opacityDisabled)
  }

  private var saved: Bool { model.termSavedAt != nil }

  /// The bare +: a new term typed from nothing (or from the selection, seeded).
  private var plain: some View {
    Button {
      model.beginAddingTerm()
    } label: {
      glyph(saved ? "checkmark" : "plus", tint: saved ? palette.signal : mutedTint)
        .frame(width: DesignTokens.Metrics.glyphHit, height: DesignTokens.Metrics.glyphHit)
        .contentShape(Circle())
    }
    .buttonStyle(KeyPressStyle())
    .accessibilityLabel("Add a key term")
  }

  /// The chip: the highlighted word, ready to add with one tap.
  private func chip(_ term: String) -> some View {
    let known = model.selectedTermIsKnown
    return HStack(spacing: DesignTokens.Metrics.addtermChipGap) {
      // Green while there is something to do, and for the moment after it
      // was done; quiet once the word is simply known.
      glyph(known ? "checkmark" : "plus", tint: known && !saved ? mutedTint : palette.signal)
      Text(term)
        .font(.system(size: DesignTokens.Typography.sizeTerm, weight: DesignTokens.Typography.weightTerm))
        .foregroundStyle(palette.keyText)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, DesignTokens.Metrics.addtermChipPad)
    .frame(height: DesignTokens.Metrics.termHeight)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Metrics.termRadius)
        .fill(palette.field)
        .strokeBorder(palette.fieldBorder, lineWidth: DesignTokens.Metrics.termBorder)
    )
    .brightness(pressed ? DesignTokens.Metrics.opacityPressBrighten : 0)
    .animation(.easeOut(duration: DesignTokens.Motion.keyPress), value: pressed)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(known ? "“\(term)” is a key term" : "Add “\(term)” as a key term")
    .accessibilityHint(known ? "" : "Hold to edit it first")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("blurt-add-selected")
    .simultaneousGesture(tapOrHold)
    // The chip hugs the word — a shorter word, a shorter chip — and only
    // shrinks, truncating the word, when the room it is offered is less:
    // the bar's remainder beside the element, or this cap in the panel. The
    // cap is an outer, invisible frame, so the chip never stretches to it.
    .frame(maxWidth: maxWidth, alignment: .leading)
  }

  /// A tap adds; a hold opens the field with the word in it; a touch that
  /// travelled (the panel's carousel) does neither.
  private var tapOrHold: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !pressed {
          pressed = true
          held = false
          hold = Task { [model] in
            try? await Task.sleep(for: .seconds(DesignTokens.Motion.chipHold))
            guard !Task.isCancelled else { return }
            held = true
            model.beginAddingTerm()
          }
        }
        if !KeyboardInteraction.isTap(value.translation) {
          hold?.cancel()
          hold = nil
        }
      }
      .onEnded { value in
        pressed = false
        hold?.cancel()
        hold = nil
        guard !held, KeyboardInteraction.isTap(value.translation) else { return }
        model.addSelectedTerm()
      }
  }

  private var mutedTint: Color { palette.keyText.opacity(DesignTokens.Metrics.opacityLegendMuted) }

  private func glyph(_ symbol: String, tint: Color) -> some View {
    Image(systemName: symbol)
      .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
      .foregroundStyle(tint)
      .contentTransition(.symbolEffect(.replace))
  }
}
