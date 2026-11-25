import XCTest

/// Runs `XCUIApplication.performAccessibilityAudit()` over every screen of the
/// iPhone app a launch can reach (debug launch flags, `BlurtiOSApp.swift`):
/// setup with and without a key, home, the try-it box with a keyboard up, the
/// consent sheet, Words, Settings, its key sheet, Output styles and the style
/// editor, the typing test, Blurt-is-on and a shared key-term list.
///
/// Each screen is audited twice: at the default text size, and at the largest
/// accessibility size (AX XXXL), where a fixed frame or a single line clips
/// for real rather than in prediction.
///
/// Subtracted, with the reason:
/// - `.contrast`, everywhere: what it flags is the brand's palette, which
///   DESIGN.md sets on purpose (`Design/tokens.json`) and this suite doesn't
///   get to change — the muted grey at 4.42:1 on the page and 4.09:1 on a card
///   in light (#777673 on #FDFCF8 / #F5F3EB), and controls drawn faded while
///   disabled. A palette change is a design decision; see DESIGN.md.
///
/// Ignored per issue (`isKnownArtifact`), with the reason:
/// - at the default size, "text clipped" and "Dynamic Type partially
///   unsupported": both are predictions about a larger size, and this suite
///   renders that size and audits it, where the audit judges the real layout
///   (a sheet's rows it predicted would clip wrap fully at AX XXXL). Every
///   other Dynamic Type finding — a font that doesn't scale at all — still
///   fails at the default size.
/// - "Dynamic Type partially unsupported" in a navigation bar or the tab bar:
///   the system bar caps its items' text and shows them through the large
///   content viewer instead, as it does in every app; Blurt's own tab bar does
///   the same on purpose (`BrandTabBar`).
/// - "text clipped" on a single-line text field: a `UITextField` scrolls its
///   text sideways rather than wrapping, by design, so a long placeholder at
///   AX XXXL runs past the edge the way it does in Apple's own apps.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
  private static let auditedTypes = XCUIAccessibilityAuditType.all.subtracting(.contrast)
  private static let largestTextSize = [
    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
  ]

  private var app = XCUIApplication()
  private var found: [String] = []
  /// The text size the screen is being audited at: launch arguments, and the
  /// name the findings carry.
  private var textSize: (arguments: [String], name: String) = ([], "default text")

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
    found = []
  }

  override func tearDown() async throws {
    app.terminate()
    try await super.tearDown()
  }

  // MARK: - Screens

  func testSetupWithoutKey() throws {
    try atEachTextSize {
      launch("-BlurtNoKey", "-SetupFinished", "NO")
      XCTAssertTrue(app.staticTexts["Paste an AssemblyAI API key to start dictating."].waitForExistence(timeout: 10))
      try auditScrolling("setup, no key")
    }
  }

  func testSetupWithKey() throws {
    try atEachTextSize {
      launch("-BlurtUITestKey", "-SetupFinished", "NO")
      XCTAssertTrue(app.staticTexts["Two more steps and you can dictate anywhere."].waitForExistence(timeout: 10))
      try auditScrolling("setup, key added")
    }
  }

  func testHome() throws {
    try atEachTextSize {
      launchHome()
      try auditScrolling("home (Dictate)")
    }
  }

  func testTryItBox() throws {
    try atEachTextSize {
      launchHome()
      let box = app.textViews["Try it here"]
      scrollTo(box)
      box.tap()
      XCTAssertTrue(
        app.keyboards.firstMatch.waitForExistence(timeout: 10), "The try-it box should bring a keyboard up")
      box.typeText("Hello")
      try audit("home, try-it box focused")
    }
  }

  func testConsent() throws {
    try atEachTextSize {
      launchHome()
      let session = app.switches.firstMatch
      scrollTo(session)
      session.tap()
      XCTAssertTrue(app.buttons["Not now"].waitForExistence(timeout: 10), "Turning a session on should ask consent")
      try auditScrolling("consent sheet")
    }
  }

  func testWords() throws {
    try atEachTextSize {
      launchHome()
      tapTab("Words")
      try auditScrolling("Words")
    }
  }

  func testSettings() throws {
    try atEachTextSize {
      launchHome()
      openSettings()
      try auditScrolling("Settings")
    }
  }

  func testStyles() throws {
    try atEachTextSize {
      launchHome()
      openSettings()
      let styles = app.buttons["Output styles"]
      scrollTo(styles)
      styles.tap()
      XCTAssertTrue(app.navigationBars["Output styles"].waitForExistence(timeout: 5))
      try auditScrolling("Settings › Output styles")
      app.buttons["New style"].tap()
      XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "New style should open the editor")
      try auditScrolling("Settings › Output styles › new style")
    }
  }

  func testKeyEntry() throws {
    try atEachTextSize {
      launchHome()
      openSettings()
      let replace = app.buttons["Replace the API key"]
      scrollTo(replace)
      replace.tap()
      XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5), "The key sheet should open")
      try audit("Settings › key entry")
    }
  }

  func testTypingTest() throws {
    try atEachTextSize {
      launch("-BlurtTypingTest")
      XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
      try auditScrolling("typing test")
    }
  }

  func testKeepOpen() throws {
    try atEachTextSize {
      launch("-BlurtKeepOpen", "-BlurtGalleryStill")
      XCTAssertTrue(app.staticTexts["Keep Blurt in the background."].waitForExistence(timeout: 10))
      try audit("Blurt is on")
    }
  }

  func testImportTerms() throws {
    try atEachTextSize {
      launch("-BlurtImportTerms")
      XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 10))
      try auditScrolling("import key terms")
    }
  }

  // MARK: - Driving

  /// Runs `body` at the default text size, then at the largest, and fails
  /// once with every finding from both.
  private func atEachTextSize(_ body: () throws -> Void) throws {
    for size in [([], "default text"), (Self.largestTextSize, "largest text")] {
      textSize = size
      try body()
      app.terminate()
    }
    // One failure per issue, each on its own line, so a CI log (which shows
    // a failure's first line) names every one.
    continueAfterFailure = true
    for issue in found { XCTFail(issue) }
  }

  /// Launches with `arguments` at the current text size, the microphone back
  /// to never-asked (so no session opens and the setup step offers Allow) and
  /// AI consent not given.
  private func launch(_ arguments: String...) { launch(arguments) }

  private func launch(_ arguments: [String]) {
    app = XCUIApplication()
    app.resetAuthorizationStatus(for: .microphone)
    app.launchArguments = arguments + ["-AIConsentVersion", "0"] + textSize.arguments
    app.launch()
  }

  /// The tabs, on Dictate, with a key in memory and setup finished.
  private func launchHome() {
    launch("-BlurtUITestKey", "-SetupFinished", "YES")
    XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10), "Home should show its gear")
  }

  private func tapTab(_ name: String) {
    let tab = app.buttons[name]
    XCTAssertTrue(tab.waitForExistence(timeout: 5), "No \(name) tab")
    tab.tap()
  }

  private func openSettings() {
    app.buttons["Settings"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Settings should open")
  }

  /// Swipes up until `element` is on screen and clear of the bars at the
  /// foot of it. A list builds its rows lazily, so one below the fold at a
  /// large text size doesn't exist until it is scrolled to.
  private func scrollTo(_ element: XCUIElement) {
    let reachable = app.frame.height * 2 / 3
    for _ in 0..<30 where !(element.exists && element.isHittable && element.frame.maxY < reachable) {
      app.swipeUp()
    }
    XCTAssertTrue(element.exists && element.isHittable, "\(element) never came on screen")
  }

  // MARK: - Auditing

  /// Audits the screen, then again after each swipe up until the page stops
  /// moving, so what starts below the fold is audited on screen too.
  private func auditScrolling(_ screen: String) throws {
    try audit(screen)
    for page in 2...16 {
      let before = screenTexts()
      app.swipeUp()
      guard screenTexts() != before else { break }
      try audit("\(screen), page \(page)")
    }
  }

  /// Every text on screen and where it is, from one snapshot: unchanged by a
  /// swipe once the page is at its end. (Not just the first text: that is a
  /// navigation bar's title on a pushed screen, which never moves.)
  private func screenTexts() -> String {
    guard let root = try? app.snapshot() else { return "" }
    var texts: [String] = []
    var pending = [root]
    while let node = pending.popLast() {
      if node.elementType == .staticText { texts.append("\(node.label)@\(node.frame.minY)") }
      pending += node.children
    }
    return texts.joined(separator: "|")
  }

  private func audit(_ screen: String) throws {
    let name = "\(screen) (\(textSize.name))"
    // What was audited, beside what it raised, in the result bundle.
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
    let isDefaultSize = textSize.arguments.isEmpty
    let bars =
      app.navigationBars.allElementsBoundByIndex.map(\.frame)
      + [app.otherElements["brand.tabBar"]].filter(\.exists)
      .map(\.frame)
    var issues: [String] = []
    try app.performAccessibilityAudit(for: Self.auditedTypes) { issue in
      if Self.isKnownArtifact(issue, atDefaultSize: isDefaultSize, bars: bars) { return true }
      issues.append(Self.describe(issue))
      return true
    }
    found += issues.map { "[\(name)] \($0)" }
  }

  /// The audit findings the type's comment explains, and nothing broader.
  private static func isKnownArtifact(
    _ issue: XCUIAccessibilityAuditIssue, atDefaultSize: Bool, bars: [CGRect]
  ) -> Bool {
    let partialDynamicType = issue.auditType == .dynamicType && issue.compactDescription.contains("partially")
    if atDefaultSize, partialDynamicType || issue.auditType == .textClipped { return true }
    guard let element = issue.element, element.exists else { return false }
    if partialDynamicType, bars.contains(where: { $0.contains(element.frame) }) {
      return true
    }
    let isTextField = [.textField, .secureTextField].contains(element.elementType)
    return issue.auditType == .textClipped && isTextField
  }

  private static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
    let element = issue.element.map { element -> String in
      guard element.exists else { return "gone" }
      return
        "type=\(element.elementType.rawValue) id='\(element.identifier)' label='\(element.label)' "
        + "value='\(String(describing: element.value))' frame=\(element.frame)"
    }
    return
      "\(name(of: issue.auditType)): \(issue.compactDescription) | \(issue.detailedDescription) | \(element ?? "no element")"
  }

  private static func name(of type: XCUIAccessibilityAuditType) -> String {
    let names: [(XCUIAccessibilityAuditType, String)] = [
      (.contrast, "contrast"), (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
      (.sufficientElementDescription, "sufficientElementDescription"), (.dynamicType, "dynamicType"),
      (.textClipped, "textClipped"), (.trait, "trait"),
    ]
    return names.first { type.contains($0.0) }?.1 ?? "type(\(type.rawValue))"
  }
}
