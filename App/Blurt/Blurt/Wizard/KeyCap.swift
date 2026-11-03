import BlurtEngine
import SwiftUI

/// A quiet keyboard legend: plain text, as a menu prints an item's shortcut,
/// with no fill or border — a key to press on the keyboard, not a control to
/// click. The real key lights it during capture.
struct KeyCap: View {
  var label: String
  var isLit = false

  var body: some View {
    Text(label)
      .fontWeight(isLit ? .semibold : .regular)
      .foregroundStyle(isLit ? AnyShapeStyle(BlurtBrand.accent) : AnyShapeStyle(.secondary))
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
