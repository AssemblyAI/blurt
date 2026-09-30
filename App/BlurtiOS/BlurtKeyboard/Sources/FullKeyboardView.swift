import SwiftUI

/// A complete keyboard laid out as the iPhone's own — ten letter keys across
/// at one width, the middle row centred, shift and delete flanking the bottom
/// letters, then 123 · globe · space · return, at the system keyboard's
/// measured spacing (`KeyGeometry`) — with the voice bar where the suggestion
/// bar would be. Letters pop up while pressed, sentences capitalise
/// themselves, a double space ends one.
/// No autocorrect or suggestions yet. iOS swaps in its own keyboard for
/// password fields, so those never reach here.
struct FullKeyboardView: View {
  var model: KeyboardModel

  private static let symbols = ["1234567890", "-/:;()$&@\"", ".,?!'"]

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
            HStack(spacing: index == 2 ? geometry.sideGap : gap) {  // literal-ok: the third row carries shift and delete
              if index == 2 { modifierKey(width: geometry.sideWidth) }  // literal-ok: the third row
              HStack(spacing: gap) {
                ForEach(Array(row), id: \.self) { character in
                  LetterKey(label: label(for: character), width: geometry.letterWidth) {
                    model.type(label(for: character))
                  }
                }
              }
              if index == 2 {
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
            KeyCap(
              title: model.returnLabel, systemImage: model.returnLabel == nil ? "return" : nil, dark: true,
              width: geometry.returnWidth
            ) { model.newline() }
          }
        }
      }
    }
  }

  private var rows: [String] { model.symbolsPage ? Self.symbols : model.letterRows }

  private func label(for character: Character) -> String {
    let text = String(character)
    return model.shifted && !model.symbolsPage ? text.uppercased() : text
  }

  @ViewBuilder private func modifierKey(width: CGFloat) -> some View {
    if model.symbolsPage {
      KeyCap(title: "#+=", dark: true, width: width) { model.toggleSymbols() }
    } else {
      KeyCap(systemImage: model.shifted ? "shift.fill" : "shift", dark: true, width: width) { model.toggleShift() }
    }
  }
}

/// A letter key with the system keyboard's 22 pt legend and its pop-up: a
/// larger copy of the letter above the key while the finger is down, so the
/// finger doesn't hide what it's pressing. Typed on release, as iOS does.
private struct LetterKey: View {
  let label: String
  let width: CGFloat
  let action: () -> Void
  @State private var pressed = false
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
          .onChanged { _ in pressed = true }
          .onEnded { value in
            pressed = false
            // A touch that travelled was a swipe (the panel's carousel), not a tap.
            guard KeyboardInteraction.isTap(value.translation) else { return }
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
