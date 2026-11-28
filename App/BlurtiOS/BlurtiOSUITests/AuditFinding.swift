import XCTest

/// One finding an audit pass raised (`auditPass`).
struct AuditFinding {
  let line: String
  /// A default-size "Dynamic Type unsupported" finding's element.
  let unscaled: XCUIElement?
  /// A largest-size "text clipped" finding's element, when it is plain text.
  let clipped: XCUIElement?
}
