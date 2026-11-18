import BlurtDesign
import BlurtiOSCore
import KeyboardKit
import SwiftUI

/// The small + at the bar's trailing end: a new key term. A bare glyph,
/// quiet until it is needed; a check for a moment after one was saved.
///
/// Highlight a word in the text and the + is a chip instead — a key's shape,
/// holding the word — and one tap adds the word as it stands: + for a word
/// Blurt doesn't know yet, ✓ once it does. After the check the + comes back,
/// highlight or not; a tap on a ✓ chip puts it back at once. Holding the
/// chip opens the field pre-filled instead, to fix the spelling first
/// (`KeyboardModel`: `selectedTerm`, `addSelectedTerm`, `beginAddingTerm`).
struct AddTermKey: View {
  var model: BlurtiOSCore.KeyboardModel
  @EnvironmentObject private var keyboardContext: KeyboardContext
  /// Lit while a finger is on the chip. A gesture state, so a touch the
  /// system takes away (a call, the keyboard dismissed mid-press) unlights it
  /// too; a plain state would stay lit.
  @GestureState private var pressed = false
  @State private var held = false

  var body: some View {
    let scheme = keyboardContext.colorScheme
    ZStack {
      if let term = model.selectedTerm {
        chip(term, scheme: scheme)
      } else {
        plain(scheme)
      }
    }
    .disabled(!model.hasFullAccess)
    .opacity(model.hasFullAccess ? 1 : DesignTokens.Metrics.opacityDisabled)
  }

  private var saved: Bool { model.termSavedAt != nil }

  /// The bare +: a new term typed from nothing (or from the selection, seeded).
  private func plain(_ scheme: ColorScheme) -> some View {
    GlyphKey(
      symbol: saved ? "checkmark" : "plus", tint: saved ? BlurtTint.signal(scheme) : Self.muted(scheme),
      label: "Add a key term"
    ) {
      model.beginAddingTerm()
    }
  }

  /// The chip: the highlighted word, ready to add with one tap.
  private func chip(_ term: String, scheme: ColorScheme) -> some View {
    let known = model.selectedTermIsKnown
    return HStack(spacing: DesignTokens.Metrics.addtermChipGap) {
      // Green while there is something to do, and for the moment after it
      // was done; quiet once the word is simply known.
      glyph(known ? "checkmark" : "plus", tint: known && !saved ? Self.muted(scheme) : BlurtTint.signal(scheme))
      Text(term)
        .font(.system(size: DesignTokens.Typography.sizeTerm, weight: DesignTokens.Typography.weightTerm))
        .foregroundStyle(BlurtTint.legend(scheme))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, DesignTokens.Metrics.addtermChipPad)
    .frame(height: DesignTokens.Metrics.termHeight)
    .frame(maxWidth: DesignTokens.Metrics.addtermChipMaxWidth)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Metrics.termRadius)
        .fill(BlurtTint.field(scheme))
        .strokeBorder(BlurtTint.edge(scheme), lineWidth: DesignTokens.Metrics.termBorder)
    )
    .brightness(pressed ? DesignTokens.Metrics.opacityPressBrighten : 0)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(known ? "“\(term)” is a key term" : "Add “\(term)” as a key term")
    .accessibilityHint(known ? "Tap to put the + back" : "Hold to edit it first")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("blurt-add-selected")
    // A hold opens the field with the word in it. The system's long press:
    // it fails on its own when the finger travels or the touch is taken
    // away, so no timer of ours can open the field after the finger is gone.
    .simultaneousGesture(
      LongPressGesture(minimumDuration: DesignTokens.Motion.chipHold, maximumDistance: KeyboardInteraction.tapTravel)
        .onEnded { _ in
          held = true
          model.beginAddingTerm()
        }
    )
    // A tap adds; a touch that travelled, or one the hold already answered,
    // does nothing.
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .updating($pressed) { _, state, _ in state = true }
        .onEnded { value in
          defer { held = false }
          guard !held,
            KeyboardInteraction.isTap(width: value.translation.width, height: value.translation.height)
          else { return }
          model.addSelectedTerm()
        }
    )
  }

  private static func muted(_ scheme: ColorScheme) -> Color {
    BlurtTint.legend(scheme).opacity(DesignTokens.Metrics.opacityLegendMuted)
  }

  private func glyph(_ symbol: String, tint: Color) -> some View {
    Image(systemName: symbol)
      .font(.system(size: DesignTokens.Typography.sizeGlyph, weight: DesignTokens.Typography.weightGlyph))
      .foregroundStyle(tint)
  }
}
