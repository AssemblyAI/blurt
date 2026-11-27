import Foundation
import XCTest

extension AccessibilityAuditTests {
  /// One audit of `app` for `types`: each finding, and the element of a
  /// default-size "Dynamic Type unsupported" one, which `scaling` checks at
  /// the largest size. The findings `isKnownArtifact` explains are left out.
  /// A pass XCTest fails to complete (`Code=-56`, the simulator didn't answer
  /// in time) fails the test: it is not run again.
  static func auditPass(
    of app: XCUIApplication,
    for types: XCUIAccessibilityAuditType,
    atDefaultSize isDefaultSize: Bool,
    bars: [CGRect],
    screen: CGRect
  ) throws -> [(line: String, unscaled: XCUIElement?)] {
    var raised: [(line: String, unscaled: XCUIElement?)] = []
    try app.performAccessibilityAudit(for: types) { issue in
      if Self.isKnownArtifact(issue, atDefaultSize: isDefaultSize, bars: bars, screen: screen) {
        return true
      }
      let unscaled = isDefaultSize && issue.auditType == .dynamicType ? issue.element : nil
      raised.append((Self.describe(issue), unscaled))
      return true
    }
    return raised
  }
}
