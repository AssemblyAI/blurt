import UIKit

// MARK: - What the host field says: the return key, the symbols page, the face

extension KeyboardModel {
  /// What the field asked for, the way the system keyboard honours it: the
  /// return key's own word, and the symbols page first for a number field.
  package func readField() {
    returnLabel = proxy?.returnKeyType.flatMap(Self.returnLabel)
  }

  package func readAppearance() {
    switch proxy?.keyboardAppearance {
    case .dark: isDark = true
    case .light: isDark = false
    default: isDark = controller?.traitCollection.userInterfaceStyle == .dark
    }
  }

  /// Number, decimal and phone fields open on the symbols page, as the system
  /// keyboard would show a number pad.
  package static func wantsSymbols(_ type: UIKeyboardType?) -> Bool {
    switch type {
    case .numberPad, .decimalPad, .phonePad, .numbersAndPunctuation, .asciiCapableNumberPad: true
    default: false
    }
  }

  /// iOS's own words for the return key, by the type the field asked for.
  package static let returnLabels: [UIReturnKeyType: String] = [
    .go: "go", .google: "search", .yahoo: "search", .search: "search", .join: "join", .next: "next",
    .route: "route", .send: "send", .done: "done", .emergencyCall: "call", .continue: "continue",
  ]

  package static func returnLabel(_ type: UIReturnKeyType) -> String? { returnLabels[type] }
}
