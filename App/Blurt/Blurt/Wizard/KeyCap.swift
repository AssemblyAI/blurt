import BlurtEngine
import SwiftUI

/// The trigger key as a small keycap chip: the shortcut row's trailing
/// control, and the empty Recent list's "tap [Right ⌘]". At rest it takes the
/// system's quaternary fill and separator — the form's own neutrals — and,
/// when `isLit`, fills with the brand accent, which is how the shortcut row
/// answers the real key going down.
struct KeyCap: View {
  var label: String
  var isLit = false
  @Environment(\.colorScheme) private var colorScheme

  /// The legend on the lit key. White on the light-mode accent (#01762F), but
  /// the dark-mode accent (#67AD82) is too pale for white to clear 4.5:1, so
  /// there the brand ink goes on it instead.
  private var legend: Color {
    guard isLit else { return .primary }
    return colorScheme == .dark ? BlurtBrand.ink : .white
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
    Text(label)
      .foregroundStyle(legend)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(shape.fill(isLit ? AnyShapeStyle(BlurtBrand.accent) : AnyShapeStyle(.quaternary)))
      .overlay(shape.strokeBorder(isLit ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 1))
      .animation(.easeOut(duration: 0.1), value: isLit)
  }
}

extension TriggerKey {
  /// The keycap's face, e.g. "Right ⌘": `label` with its leading capital,
  /// since a key's legend is a title rather than mid-sentence prose — except
  /// `fn`, which Apple keyboards print lowercase.
  var keycapLabel: String {
    if self == .function { return label }
    return label.prefix(1).uppercased() + label.dropFirst()
  }

  /// The key named in words, e.g. "Right Command": `fullName` without its
  /// parenthesised symbol. VoiceOver hears it without the symbol read as
  /// the name a second time.
  var spokenName: String {
    guard let symbol = fullName.range(of: " (") else { return fullName }
    return String(fullName[..<symbol.lowerBound])
  }
}
