import SwiftUI

/// One turn: the name in the speaker's colour, the words beneath, on a wash
/// of the colour — the same padding on every turn keeps the text aligned.
struct TurnBlock: View {
  let name: String
  let text: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name)
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
      Text(text)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
