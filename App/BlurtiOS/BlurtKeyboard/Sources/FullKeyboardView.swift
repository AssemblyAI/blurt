import SwiftUI

/// A complete keyboard laid out as the iPhone's own — ten letter keys across
/// at one width, the middle row centred, shift and delete flanking the bottom
/// letters, then 123 · globe · space · return, at the system keyboard's
/// measured spacing (`KeyGeometry`) — with the voice bar where the suggestion
/// bar would be. Letters pop up while pressed, sentences capitalise
/// themselves, a double space ends one. 123 opens the numbers and symbols,
/// #+= the rest of them, as the system keyboard's pages go.
/// No autocorrect or suggestions yet. iOS swaps in its own keyboard for
/// password fields, so those never reach here.
struct FullKeyboardView: View {
  var model: KeyboardModel

  private static let symbols = ["1234567890", "-/:;()$&@\"", ".,?!'"]
  private static let more = ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]

  var body: some View {
    GeometryReader { geo in
      // The root has already taken the side margins off; the rest is the row.
      let geometry = KeyGeometry(rowWidth: geo.size.width)
      let gap = geometry.gap
      VStack(spacing: 0) {
        // The voice row sits where the system's suggestion bar does, and the
        // first key row starts right under it, as the iPhone's does.
        VoiceBar(model: model)
        VStack(spacing: KeyboardPalette.rowGap) {
          ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            let third = index == 2  // literal-ok: the third row
            // The third row's keys fill what shift and delete leave: seven
            // letters at the letter width, or the five punctuation keys, wider,
            // as the system keyboard has them on its symbol pages.
            let keyWidth = third && model.symbolsPage ? geometry.punctuationWidth : geometry.letterWidth
            HStack(spacing: third ? geometry.sideGap : gap) {
              if third { modifierKey(width: geometry.sideWidth) }
              HStack(spacing: gap) {
                ForEach(Array(row), id: \.self) { character in
                  LetterKey(label: label(for: character), width: keyWidth) {
                    model.type(label(for: character))
                  }
                }
              }
              if third {
                KeyCap(systemImage: "delete.left", dark: true, width: geometry.sideWidth) { model.deleteBackward() }
              }
            }
            .frame(maxWidth: .infinity)
          }
          // The stock bottom row; voice lives only in the bar above.
          HStack(spacing: gap) {
            KeyCap(title: model.symbolsPage ? "ABC" : "123", dark: true, width: geometry.abcWidth) {
              model.toggleSymbols()
            }
            if model.needsGlobe {
              KeyCap(systemImage: "globe", dark: true, width: geometry.abcWidth) { model.globe() }
            }
            KeyCap(title: "space", flexible: true) { model.space() }
            KeyCap(title: model.returnLabel ?? "return", dark: true, width: geometry.returnWidth) { model.newline() }
          }
        }
      }
    }
  }

  private var rows: [String] {
    guard model.symbolsPage else { return model.letterRows }
    return model.morePage ? Self.more : Self.symbols
  }

  private func label(for character: Character) -> String {
    let text = String(character)
    return model.shifted && !model.symbolsPage ? text.uppercased() : text
  }

  /// Shift on the letters; on the symbol pages the key that swaps between
  /// the two of them, labelled with where it goes, as the iPhone's is.
  @ViewBuilder private func modifierKey(width: CGFloat) -> some View {
    if model.symbolsPage {
      KeyCap(title: model.morePage ? "123" : "#+=", dark: true, width: width) { model.toggleMore() }
    } else {
      KeyCap(systemImage: model.shifted ? "shift.fill" : "shift", dark: true, width: width) { model.toggleShift() }
    }
  }
}

/// A letter key with the system keyboard's 24 pt legend and its pop-up: a
/// larger copy of the letter above the key while the finger is down, so the
/// finger doesn't hide what it's pressing. Typed on release, as iOS does.
private struct LetterKey: View {
  let label: String
  let width: CGFloat
  let action: () -> Void
  /// A gesture state, so a touch the system takes away unlights the key and
  /// drops its pop-up; a plain state would leave both up.
  @GestureState private var pressed = false
  @Environment(\.keyboardPalette) private var palette
  @Environment(\.keyboardInContainer) private var inContainer

  var body: some View {
    Text(label)
      .font(.system(size: DesignTokens.Typography.sizeLetter, weight: DesignTokens.Typography.weightLetter))
      .foregroundStyle(palette.keyText)
      .frame(width: width, height: KeyCap.height)
      .keyCap(palette.keyFill(modifier: false, inContainer: inContainer))
      .overlay(alignment: .top) {
        if pressed { popup }
      }
      .zIndex(pressed ? 1 : 0)
      .contentShape(Rectangle())
      .accessibilityLabel(label)
      .accessibilityAddTraits(.isButton)
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .updating($pressed) { _, state, _ in state = true }
          .onEnded { value in
            // A touch that swiped away (the panel's carousel) was not a tap;
            // one that ended on the key was, wherever the thumb rolled.
            guard
              KeyboardInteraction.isTap(
                value.translation, endedAt: value.location, in: CGSize(width: width, height: KeyCap.height))
            else { return }
            action()
          }
      )
  }

  private var popup: some View {
    Text(label)
      .font(.system(size: DesignTokens.Typography.sizePopup, weight: DesignTokens.Typography.weightPopup))
      .foregroundStyle(palette.keyText)
      .frame(width: width + DesignTokens.Metrics.popupExtraWidth, height: DesignTokens.Metrics.popupHeight)
      .background(palette.popupFill, in: RoundedRectangle(cornerRadius: DesignTokens.Metrics.popupRadius))
      .shadow(
        color: .black.opacity(DesignTokens.Metrics.opacityPopupShadow), radius: DesignTokens.Metrics.popupShadowRadius,
        y: DesignTokens.Metrics.popupShadowY
      )
      .offset(y: -DesignTokens.Metrics.popupOffset)
      .allowsHitTesting(false)
  }
}
