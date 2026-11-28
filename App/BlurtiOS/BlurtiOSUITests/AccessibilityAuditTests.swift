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
///   (a sheet's rows it predicted would clip wrap fully at AX XXXL).
/// - "Dynamic Type partially unsupported" in a navigation bar or the tab bar:
///   the system bar caps its items' text and shows them through the large
///   content viewer instead, as it does in every app; Blurt's own tab bar does
///   the same on purpose (`BrandTabBar`).
/// - "text clipped" and "Dynamic Type partially unsupported" on text that
///   runs under a bar or off the screen's edge: the audit reads the screen's
///   edge as the text's, and `auditScrolling` brings that text fully on
///   screen on another page, where it is audited whole.
/// - an issue the audit can't tie to any element: on a scrolled page it is
///   the text sliding under the translucent navigation bar (Settings' rows
///   between two pages), which the audit can measure but not name; the same
///   text is audited, and named, on the page where it is in full view.
/// - anything on a word-suggestion slot of Apple's keyboard
///   (`TUIPredictionViewCell`), up for the try-it box: on CI the simulator
///   sometimes leaves a slot empty after "Hello", and an empty slot has no
///   label. It is the system keyboard's, which Blurt can't label, and it stays
///   empty through the second audit. Matched by that class, so a Blurt element
///   without a description still fails.
/// - "text clipped" on a single-line text field: a `UITextField` scrolls its
///   text sideways rather than wrapping, by design, so a long placeholder at
///   AX XXXL runs past the edge the way it does in Apple's own apps.
/// Nothing is excused by name: the "Professional" preset chip and the consent
/// sheet's "Sent to AssemblyAI" rows were, until their layouts were fixed
/// (`PresetChip` draws its name unshrunk at accessibility sizes;
/// `WrappingLabelStyle` lays its icon and title out itself).
///
/// A default-size "Dynamic Type unsupported" is checked rather than taken on
/// the audit's word (`ScalingCheck`): it fails only if the same text is no
/// taller at AX XXXL. On CI the audit intermittently said it of Settings'
/// last rows while they scaled. A font that doesn't scale stays the same
/// height, so it still fails, and the failure says how tall it was at each
/// size.
///
/// Nothing is run again in the hope of a different answer: not a tap, not an
/// audit pass XCTest timed out on, not a screen that raised a finding. Pages
/// are reached by a fixed drag rather than a fling (`drag`), so every run
/// audits the same screens and a finding either holds or doesn't.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
  private static let auditedTypes = XCUIAccessibilityAuditType.all.subtracting(.contrast)
  private static let largestTextSize = [
    "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
  ]

  private var app = XCUIApplication()
  private var found: [String] = []
  /// Default-size "Dynamic Type unsupported" findings, failed only if the
  /// largest size shows the text didn't grow.
  private var scaling = ScalingCheck()
  /// The text size the screen is being audited at: launch arguments, and the
  /// name the findings carry.
  private var textSize: (arguments: [String], name: String) = ([], "default text")

  /// The cold first launch, once, before any test (`warmFirstLaunch`). XCTest
  /// calls this on the main thread.
  override nonisolated static func setUp() {
    super.setUp()
    MainActor.assumeIsolated { warmFirstLaunch() }
  }

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false
    found = []
    scaling = ScalingCheck()
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
        app.keyboards.firstMatch.waitForExistence(timeout: 10),
        "The try-it box should bring a keyboard up"
      )
      box.typeText("Hello")
      try audit("home, try-it box focused")
    }
  }

  func testConsent() throws {
    try atEachTextSize {
      // Raised at launch over home (`-BlurtAskConsent`), as turning a session
      // on raises it: the suite audits the sheet, not the switch, and a tap on
      // the switch just after a fresh install's launch could land before the
      // app took touches, leaving it off with no sheet (PR #451's queue run).
      launch("-BlurtUITestKey", "-SetupFinished", "YES", "-BlurtAskConsent")
      let notNow = app.buttons["Not now"]
      XCTAssertTrue(notNow.waitForExistence(timeout: 10), "-BlurtAskConsent should raise the consent sheet")
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
      XCTAssertTrue(app.navigationBars["API key"].waitForExistence(timeout: 10), "The key sheet should open")
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
  ///
  /// `BLURT_AUDIT_TEXT_SIZE` (`default` or `largest`, through ios-uitest.sh)
  /// keeps a run to one of the two, for iterating on one size by hand; CI
  /// audits both, splitting the suite across runners by test instead. Any
  /// other value fails rather than auditing nothing.
  private func atEachTextSize(_ body: () throws -> Void) throws {
    let selected = ProcessInfo.processInfo.environment["BLURT_AUDIT_TEXT_SIZE"] ?? ""
    let sizes = [([String](), "default text"), (Self.largestTextSize, "largest text")]
      .filter { selected.isEmpty || $0.1.hasPrefix(selected + " ") }
    guard !sizes.isEmpty else {
      XCTFail("BLURT_AUDIT_TEXT_SIZE must be default or largest, not '\(selected)'")
      return
    }
    for size in sizes {
      textSize = size
      try body()
      app.terminate()
    }
    found += scaling.unscaled()
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

  /// Drags the page a third of the screen at a time until `element` sits in
  /// the middle band, clear of the bars at either end: a swipe flings a long
  /// page at a large text size straight past a row. A list builds its rows
  /// lazily, so one below the fold doesn't exist until it is scrolled to.
  private func scrollTo(_ element: XCUIElement) {
    let height = app.frame.height
    let band = (height * 0.25)...(height * 0.7)
    for _ in 0..<40 {
      guard element.exists else {
        Self.drag(app, by: -height / 3)
        continue
      }
      let y = element.frame.midY
      if band.contains(y) { break }
      Self.drag(app, by: y > band.upperBound ? -height / 4 : height / 4)
    }
    // At rest before anyone taps it: a tap while the list still coasts from
    // the last drag only stops the scroll and never reaches the control, which
    // on a slow runner left `testConsent`'s switch off and no consent sheet.
    var frame = element.frame
    for _ in 0..<20 {
      Thread.sleep(forTimeInterval: 0.2)  // wall-clock-ok: a UI test: the app under test runs on real time
      let now = element.frame
      if now == frame { break }
      frame = now
    }
    XCTAssertTrue(element.exists && element.isHittable, "\(element) never came on screen")
  }

  // MARK: - Auditing

  /// Audits the screen, then again after each page's drag until the page
  /// shows nothing it hasn't shown before, so what starts below the fold is
  /// audited on screen too. (A sheet at its end can rock between two resting
  /// places, so "unchanged since the last drag" isn't enough.) Each drag runs
  /// from low on the screen, clear of the tab bar, most of the way up: a
  /// fixed distance, so every run audits the same pages (`drag`).
  ///
  /// A screen still scrolling after `maxPages` fails rather than stopping
  /// quietly: the cap once cut Settings short at the largest text size, so
  /// its last rows were never on screen to be measured there, and a default-
  /// size finding about them that `ScalingCheck` would have cleared failed.
  private func auditScrolling(_ screen: String) throws {
    let maxPages = 48
    try audit(screen)
    var seen: Set = [screenTexts()]
    for page in 2...maxPages {
      Self.drag(app, by: -app.frame.height * 0.7, from: 0.85)
      guard seen.insert(screenTexts()).inserted else {
        return
      }
      try audit("\(screen), page \(page)")
    }
    XCTFail("[\(screen) (\(textSize.name))] still scrolling after \(maxPages) pages; its end was never audited")
  }

  /// Every text on screen and where it is, from one snapshot: unchanged by a
  /// swipe once the page is at its end. (Not just the first text: that is a
  /// navigation bar's title on a pushed screen, which never moves.)
  private func screenTexts() -> String {
    // Past the bounce a drag past the end sets off: snapshot until two
    // in a row agree, rather than after a fixed pause. A slow runner (CI's
    // takes half as long again as a Mac) can still be settling the last page
    // after 0.6 s, and an audit of rows in motion reads their Dynamic Type
    // wrong (`audit`).
    var last = Self.textsOnScreen(of: app)
    for _ in 0..<20 {
      Thread.sleep(forTimeInterval: 0.3)  // wall-clock-ok: a UI test: the app under test runs on real time
      let current = Self.textsOnScreen(of: app)
      if current == last {
        return current
      }
      last = current
    }
    return last
  }

  private func audit(_ screen: String) throws {
    // Never mid-change: the audit reads the whole hierarchy, and a screen
    // still laying out (a launch, a keyboard coming up) is when it timed out.
    _ = screenTexts()
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
    let screenArea = app.windows.firstMatch.frame
    let issues = try Self.auditPass(
      of: app, for: Self.auditedTypes, atDefaultSize: isDefaultSize, bars: bars, screen: screenArea
    )
    for issue in issues {
      let finding = "[\(name)] \(issue.line)"
      if let element = issue.unscaled, element.exists {
        scaling.hold(finding, about: element, in: app, within: screenArea)
      } else {
        found.append(finding)
      }
    }
    if !isDefaultSize {
      scaling.measure(in: app, within: screenArea)
    }
  }
}
