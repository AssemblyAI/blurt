import SwiftUI

/// A complete keyboard with the mic as the main key. Letters, shift, a symbols
/// page, space and return — enough to fix a typo without leaving Blurt; no
/// autocorrect or suggestions yet. iOS swaps in its own keyboard for password
/// and phone-number fields, so those never reach here. 252 pt: the pill, three
/// rows of letters and the bottom row, each row `KeyCap.height`.
struct FullKeyboardView: View {
  var model: KeyboardModel

  private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
  private static let symbols = ["1234567890", "-/:;()$&@\"", ".,?!'"]

  var body: some View {
    VStack(spacing: KeyboardRootView.rowGap) {
      StatusPill(model: model)
        .frame(maxWidth: 260)
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        HStack(spacing: 5) {
          if index == 2 { modifierKey }
          ForEach(Array(row), id: \.self) { character in
            LetterKey(label: label(for: character)) { model.type(label(for: character)) }
          }
          if index == 2 { KeyCap(systemImage: "delete.left", dark: true) { model.deleteBackward() } }
        }
      }
      HStack(spacing: 6) {
        if model.needsGlobe { KeyCap(systemImage: "globe", dark: true) { model.globe() } }
        KeyCap(title: model.symbolsPage ? "ABC" : "123", dark: true) { model.toggleSymbols() }
        KeyCap(title: "space", flexible: true) { model.space() }
        MicKey(model: model, size: KeyCap.height)
        KeyCap(systemImage: "return", dark: true) { model.newline() }
      }
    }
  }

  private var rows: [String] { model.symbolsPage ? Self.symbols : Self.letters }

  private func label(for character: Character) -> String {
    let text = String(character)
    return model.shifted && !model.symbolsPage ? text.uppercased() : text
  }

  @ViewBuilder private var modifierKey: some View {
    if model.symbolsPage {
      KeyCap(title: "#+=", dark: true) { model.toggleSymbols() }
    } else {
      KeyCap(systemImage: model.shifted ? "shift.fill" : "shift", dark: true) { model.toggleShift() }
    }
  }
}

/// A letter key: narrower than `KeyCap` so ten fit across a phone, with the
/// system keyboard's 22 pt legend.
private struct LetterKey: View {
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: 22))
        .foregroundStyle(BlurtBrand.keyText)
        .frame(maxWidth: .infinity, minHeight: KeyCap.height)
        .background(BlurtBrand.key, in: RoundedRectangle(cornerRadius: KeyCap.cornerRadius))
        .overlay(
          RoundedRectangle(cornerRadius: KeyCap.cornerRadius).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
    .buttonStyle(KeyPressStyle())
  }
}
