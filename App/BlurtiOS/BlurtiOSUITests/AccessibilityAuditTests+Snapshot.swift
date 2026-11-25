import XCTest

extension AccessibilityAuditTests {
  /// One snapshot's texts and where they are (`screenTexts`).
  static func textsOnScreen(of app: XCUIApplication) -> String {
    guard let root = try? app.snapshot() else {
      return ""
    }
    let screen = root.frame
    var texts: [String] = []
    var pending = [root]
    while let node = pending.popLast() {
      if node.elementType == .staticText, screen.intersects(node.frame) {
        texts.append("\(node.label)@\(Int(node.frame.minY))")
      }
      pending += node.children
    }
    return texts.joined(separator: "|")
  }
}
