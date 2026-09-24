import SwiftUI

/// A complete keyboard with the mic as the main key. Letters, shift, a symbols
/// page, space and return — enough to fix a typo without leaving Blurt; no
/// autocorrect or suggestions yet. iOS swaps in its own keyboard for password
/// and phone-number fields, so those never reach here.
struct FullKeyboardView: View {
  var model: KeyboardModel

  private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
  private static let symbols = ["1234567890", "-/:;()$&@\"", ".,?!'"]

  var body: some View {
    VStack(spacing: 8) {
      StatusPill(model: model)
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        HStack(spacing: 5) {
          if index == 2 { modifierKey }
          ForEach(Array(row), id: \.self) { character in
            LetterKey(label: label(for: character)) { model.type(label(for: character)) }
          }
          if index == 2 { KeyCap(systemImage: "delete.left") { model.deleteBackward() } }
        }
      }
      HStack(spacing: 6) {
        if model.needsGlobe { KeyCap(systemImage: "globe") { model.globe() } }
        KeyCap(title: model.symbolsPage ? "ABC" : "123") { model.toggleSymbols() }
        KeyCap(title: "space", flexible: true) { model.space() }
        MicKey(model: model, size: 44)
        KeyCap(systemImage: "return") { model.newline() }
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
      KeyCap(title: "#+=") { model.toggleSymbols() }
    } else {
      KeyCap(systemImage: model.shifted ? "shift.fill" : "shift") { model.toggleShift() }
    }
  }
}

/// A letter key: narrower than `KeyCap` so ten fit across a phone.
private struct LetterKey: View {
  let label: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: 21))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
  }
}
