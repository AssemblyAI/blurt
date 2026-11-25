import XCTest

/// Tapping a control and seeing the tap take: how `testConsent` turns the
/// session switch on.
extension AccessibilityAuditTests {
  /// Taps `control` and waits for `shown`, tapping once more when `shown`
  /// hasn't come by half of `timeout` and `control` is still there to tap. On
  /// CI only, a tap on the session switch has landed and done nothing — the
  /// switch stayed off and no consent sheet came — even after `scrollTo`
  /// waited for the list to rest. A tap that took has shown `shown` long
  /// before the second look, so the control is never tapped twice then.
  static func tap(_ control: XCUIElement, until shown: XCUIElement, timeout: TimeInterval) -> Bool {
    control.tap()
    if shown.waitForExistence(timeout: timeout / 2) {
      return true
    }
    if !shown.exists, control.isHittable {
      control.tap()
    }
    return shown.waitForExistence(timeout: timeout / 2)
  }

  /// What the screen held when `shown` never came, for the failure's message:
  /// the control's state and any alert over the app. CI uploads no result
  /// bundle from this suite, so the log line is all a failure leaves behind.
  static func missedTapReport(_ control: XCUIElement, in app: XCUIApplication) -> String {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let alerts = (app.alerts.allElementsBoundByIndex + springboard.alerts.allElementsBoundByIndex).map(\.label)
    return "control exists \(control.exists), hittable \(control.isHittable), value \(control.value ?? "none"); "
      + "alerts \(alerts); sheets \(app.sheets.count)"
  }
}
