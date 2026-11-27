import XCTest

/// Driving the screen by touch: the one way the audits scroll, and what a tap
/// that didn't take leaves behind.
extension AccessibilityAuditTests {
  /// Drags the page by `distance` points (negative scrolls down the page),
  /// from `start` (a fraction of the screen's height) at a slow, fixed speed,
  /// then holds still before lifting, so the list stops where the finger did
  /// instead of coasting. A fling (`swipeUp`) travels as far as the touch
  /// events' timing makes it, which a slow runner distorts: each run audited a
  /// page at a slightly different scroll position, and findings near a bar or
  /// the screen's edge came and went with it. This lands every run on the same
  /// pages.
  static func drag(_ app: XCUIApplication, by distance: CGFloat, from start: CGFloat = 0.5) {
    let finger = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
    finger.press(
      forDuration: 0.05,
      thenDragTo: finger.withOffset(CGVector(dx: 0, dy: distance)),
      withVelocity: .slow,
      thenHoldForDuration: 0.3
    )
  }

  /// What the screen held when a tap's result never came, for the failure's
  /// message: the control's state and any alert over the app. The log shows a
  /// failure's first line, so it is the one place every reader sees.
  static func missedTapReport(_ control: XCUIElement, in app: XCUIApplication) -> String {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let alerts = (app.alerts.allElementsBoundByIndex + springboard.alerts.allElementsBoundByIndex).map(\.label)
    return "control exists \(control.exists), hittable \(control.isHittable), value \(control.value ?? "none"); "
      + "alerts \(alerts); sheets \(app.sheets.count)"
  }
}
