import XCTest

/// Sorting what the audit raises: the findings `AccessibilityAuditTests`'
/// comment explains, and the line each other finding fails with.
extension AccessibilityAuditTests {
  /// How far below a navigation bar iOS 26's scroll-edge effect softens the
  /// content scrolling under it.
  static let scrollEdge: CGFloat = 44

  /// The class of a word-suggestion slot in the bar above Apple's keyboard,
  /// as the audit names it.
  static let predictionCell = "TUIPredictionViewCell"

  /// The consent sheet's "Sent to AssemblyAI" rows, by their exact text
  /// (`ConsentView`): what `isKnownArtifact` excuses "text clipped" on, and
  /// nothing else on the sheet.
  static let consentDisclosures: Set = [
    "Your voice while you dictate",
    "The text just before your cursor",
    "Your recent dictations",
    "Your key terms, including contact names",
  ]

  /// The audit findings the type's comment explains, and nothing broader.
  static func isKnownArtifact(
    _ issue: XCUIAccessibilityAuditIssue,
    atDefaultSize: Bool,
    bars: [CGRect],
    screen: CGRect
  ) -> Bool {
    let partialDynamicType = issue.auditType == .dynamicType && issue.compactDescription.contains("partially")
    if atDefaultSize, partialDynamicType || issue.auditType == .textClipped {
      return true
    }
    // Apple's keyboard, not Blurt's screen: the class name is the only thing
    // that tells its suggestion slots apart from a Blurt element.
    if issue.detailedDescription.contains(predictionCell) {
      return true
    }
    guard let element = issue.element else {
      return true
    }
    guard element.exists else {
      return false
    }
    let frame = element.frame
    if partialDynamicType, bars.contains(where: { $0.contains(frame) }) {
      return true
    }
    // The bar's own frame, and the soft edge iOS 26 blurs under it.
    let underBar = bars.contains { bar in
      let edge = bar.insetBy(dx: 0, dy: -scrollEdge)
      return edge.intersects(frame) && !bar.contains(frame)
    }
    if partialDynamicType || issue.auditType == .textClipped, underBar || !screen.contains(frame) {
      return true
    }
    let isTextField = [.textField, .secureTextField].contains(element.elementType)
    let isProfessionalChip = element.elementType == .staticText && element.label == "Professional"
    let isConsentDisclosure = element.elementType == .staticText && consentDisclosures.contains(element.label)
    return issue.auditType == .textClipped && (isTextField || isProfessionalChip || isConsentDisclosure)
  }

  /// One line: what the audit says, and the element it says it about.
  static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
    var line = "\(issue.compactDescription) (\(issue.detailedDescription))"
    if let element = issue.element, element.exists {
      line += " on \(element.elementType) \"\(element.label)\" at \(element.frame)"
    }
    return line
  }
}
