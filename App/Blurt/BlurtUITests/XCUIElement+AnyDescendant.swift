import XCTest

@MainActor
extension XCUIElement {
  /// The first descendant carrying `identifier`, matched across *all* element
  /// types. AppKit may expose a given SwiftUI control as a switch, a checkbox, or
  /// a static text — and which one can change between macOS releases — so these
  /// lookups must not be scoped by element type. Stated once here so a future
  /// change in how a control surfaces is one fix, not four.
  func anyDescendant(identified identifier: String) -> XCUIElement {
    descendants(matching: .any).matching(identifier: identifier).firstMatch
  }
}
