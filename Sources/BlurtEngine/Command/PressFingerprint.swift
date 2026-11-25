/// What a press is judged by: the app's focused element, its focused
/// window's title, the pressed element's value, and whether it's still on
/// screen. The same before and after means the press changed nothing Blurt
/// can see, and a click is tried instead.
struct PressFingerprint {
  /// The focused element's identity (`CFHash`), not its contents. Bit-pattern
  /// converted from the unsigned `CFHashCode`: a plain `Int(_:)` traps on any
  /// hash with the top bit set, and only equality is ever asked of it.
  let focusedElement: Int?
  let windowTitle: String?
  let value: String?
  let onScreen: Bool
  /// Whether the focus is on the pressed element, or inside it.
  var focusOnTarget = false
  /// Whether it's expanded (`AXExpanded`): a web menu's title opening its
  /// menu changes this and nothing else. Nil when the element has no
  /// `AXExpanded` at all, which is not the same reading as collapsed.
  var expanded: Bool?  // swiftlint:disable:this discouraged_optional_boolean

  /// Whether anything a working press would change is different from
  /// `earlier`. Focus moving onto the pressed element itself isn't: Slack's
  /// sidebar row takes the focus on a press and opens nothing (2026-11-04).
  func changed(since earlier: Self) -> Bool {
    (focusedElement != earlier.focusedElement && !focusOnTarget) || windowTitle != earlier.windowTitle
      || value != earlier.value || onScreen != earlier.onScreen || expanded != earlier.expanded
  }
}
