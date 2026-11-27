import XCTest

extension AccessibilityAuditTests {
  /// Launches the app once, before the class's first test, and waits until
  /// its screen holds still: the runner installs the app afresh at the start
  /// of the run (~20 s on CI), and the first launch after that is the cold
  /// one. The shard's first test bore both — the accessibility audit timed
  /// out reading that launch's screen (`testSetupWithKey`, run 46055375031),
  /// and a tap went in before the app took touches (`testConsent`). Bounded:
  /// a screen that never holds still is left to the tests to report.
  static func warmFirstLaunch() {
    let app = XCUIApplication()
    app.launchArguments = ["-BlurtUITestKey", "-SetupFinished", "YES"]
    app.launch()
    var last = textsOnScreen(of: app)
    for _ in 0..<60 {
      Thread.sleep(forTimeInterval: 0.5)  // wall-clock-ok: a UI test: the app under test runs on real time
      let now = textsOnScreen(of: app)
      if !now.isEmpty, now == last {
        break
      }
      last = now
    }
    app.terminate()
  }

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
