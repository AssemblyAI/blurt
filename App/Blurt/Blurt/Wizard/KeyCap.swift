import BlurtEngine
import SwiftUI

/// A key's name drawn as a keycap — a small raised key, as shortcut hints are
/// drawn — so it reads as a key to press on the keyboard, not a control to
/// click. It stays as it is while the key is down.
struct KeyCap: View {
  var label: String

  var body: some View {
    Text(label)
      .font(.callout)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color(nsColor: .textBackgroundColor))
          .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(Color(nsColor: .separatorColor))
      )
  }
}

extension TriggerKey {
  /// The key named in words, e.g. "Right Command": `fullName` without its
  /// parenthesised symbol. The one name a key goes by on screen — the main
  /// window's legend, the menu bar, and every Settings row — and what VoiceOver
  /// hears, without the symbol read as the name a second time.
  var spokenName: String {
    guard let symbol = fullName.range(of: " (") else { return fullName }
    return String(fullName[..<symbol.lowerBound])
  }
}

extension TriggerKeyAction {
  /// The action's row icon — the main window's key rows and the Keys tab's
  /// action rows, so an action looks the same in both.
  var systemImage: String {
    switch self {
    case .readAloud: LibraryKind.readAloud.systemImage
    case .ask: LibraryKind.ask.systemImage
    case .rewrite: "pencil.line"
    case .compose: "square.and.pencil"
    case .command: "command"
    case .dictate, .off: "keyboard"
    }
  }
}
