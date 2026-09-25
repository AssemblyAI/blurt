import SwiftUI

/// A complete keyboard with the mic as the main key, laid out as the iPhone's
/// own: ten letter keys across at one width, the middle row centred, shift
/// and delete flanking the bottom letters, then 123 · globe · space · mic ·
/// return. Every key is 42 pt tall; the look sets the gaps. Letters pop up
/// while pressed, sentences capitalise themselves, a double space ends one.
/// No autocorrect or suggestions yet. iOS swaps in its own keyboard for
/// password and phone-number fields, so those never reach here.
struct FullKeyboardView: View {
  var model: KeyboardModel

  private static let letters = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
  private static let symbols = ["1234567890", "-/:;()$&@\"", ".,?!'"]

  var body: some View {
    GeometryReader { geo in
      let gap = model.theme.keyGap
      // Ten keys and nine gaps across the row.
      let keyWidth = (geo.size.width - 9 * gap) / 10
      // Shift and delete take what seven letters leave, standing a little
      // further from them than letters stand from each other.
      let sideGap = gap * 2
      let sideWidth = (geo.size.width - 7 * keyWidth - 6 * gap - 2 * sideGap) / 2
      VStack(spacing: model.theme.rowGap) {
        StatusPill(model: model)
          .frame(maxWidth: 260)
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          HStack(spacing: index == 2 ? sideGap : gap) {
            if index == 2 { modifierKey(width: sideWidth) }
            HStack(spacing: gap) {
              ForEach(Array(row), id: \.self) { character in
                LetterKey(label: label(for: character), width: keyWidth) { model.type(label(for: character)) }
              }
            }
            if index == 2 {
              KeyCap(systemImage: "delete.left", dark: true, width: sideWidth) { model.deleteBackward() }
            }
          }
          .frame(maxWidth: .infinity)
        }
        HStack(spacing: gap) {
          if model.needsGlobe { KeyCap(systemImage: "globe", dark: true, width: sideWidth) { model.globe() } }
          KeyCap(title: model.symbolsPage ? "ABC" : "123", dark: true, width: sideWidth) { model.toggleSymbols() }
          KeyCap(title: "space", flexible: true) { model.space() }
          MicKey(model: model, size: KeyCap.height)
          KeyCap(systemImage: "return", dark: true, width: sideWidth * 2 + gap) { model.newline() }
        }
      }
    }
  }

  private var rows: [String] { model.symbolsPage ? Self.symbols : Self.letters }

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

  var body: some View {
    Text(label)
      .font(.system(size: 22))
      .foregroundStyle(palette.keyText)
      .frame(width: width, height: KeyCap.height)
      .keyCap(palette.key, palette: palette)
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
          .onEnded { _ in
            pressed = false
            action()
          }
      )
  }

  private var popup: some View {
    Text(label)
      .font(.system(size: 32))
      .foregroundStyle(palette.keyText)
      .frame(width: width + 18, height: 56)
      .background(palette.popupFill, in: RoundedRectangle(cornerRadius: 9))
      .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
      .offset(y: -58)
      .allowsHitTesting(false)
  }
}
