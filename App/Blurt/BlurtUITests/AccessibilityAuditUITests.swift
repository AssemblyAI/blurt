import XCTest

/// What `performAccessibilityAudit()` checks on the Mac: element detection
/// and hit regions, the two macOS audits that report on this app's own views.
/// The macOS SDK offers six types (contrast, element detection, hit region,
/// sufficient element description, action, parent/child); the other four are
/// subtracted because every finding they raise is framework or system
/// behaviour, re-tested against the whole suite below on 2026-11-24 (macOS 26
/// runner, the audits run with each category included and every issue listed):
///
/// - `.contrast`: every finding is text in the system's secondary label colour
///   (captions, row subtitles, "Not connected"), whose on-screen contrast macOS
///   manages through vibrancy, or text in a window behind the one in front —
///   the audit reads every window, and AppKit dims an inactive window's text by
///   design (the wizard's "API Key", "Microphone" behind Settings). Darkening
///   the captions would fight the native idiom.
/// - `.sufficientElementDescription`: raised only by the hosting groups
///   SwiftUI wraps each window's content in, and the runner's Touch Bar. Not
///   interactive and carrying no information, so there is nothing to describe.
/// - `.action`: raised on every SwiftUI `Picker` pop-up (Settings' key, sound,
///   voice, speed, microphone and mode pickers), every toolbar `Menu` (the
///   Library's Filter, a transcript's View) and the system's "emoji & symbols"
///   control: AppKit exposes them as pop-ups that open with `AXShowMenu`, which
///   the check doesn't count. VoiceOver opens them fine.
/// - `.parentChild`: raised on the same hosting groups, often with no element
///   to name — an AX-snapshot inconsistency that survives the audit's own
///   retries, a framework bug, not this app's hierarchy.
///
/// Re-run with a category included when the SDK or the runner's macOS moves:
/// drop it from the list below and read what the audit lists.
private let auditedTypes: XCUIAccessibilityAuditType = .all.subtracting([
  .contrast, .sufficientElementDescription, .action, .parentChild,
])

extension BlurtUITestCase {
  /// Audits the whole app as it stands — every window, the menu bar's menu
  /// and the overlay pill included — collecting each issue into `found` under
  /// `screen` rather than failing on the first, so one run names every issue
  /// on every screen a test visits. Issues raised by the UI-test harness's own
  /// window are skipped: it is test scaffolding, never shipped.
  func audit(_ screen: String, into found: inout [String]) throws {
    let harness = app.windows[UITestIdentifiers.harnessWindowTitle]
    let harnessFrame = harness.exists ? harness.frame : .null
    var issues: [String] = []
    try app.performAccessibilityAudit(for: auditedTypes) { issue in
      if let element = issue.element, element.exists, harnessFrame.contains(element.frame) { return true }
      issues.append(
        "[\(screen)] \(issue.compactDescription): \(issue.detailedDescription) — \(Self.name(issue.element))")
      return true
    }
    found += issues
  }

  /// Fails once per issue `found` holds, each on its own line, so a CI log
  /// (which shows a failure's first line) names every one.
  func assertNoAccessibilityIssues(_ found: [String]) {
    continueAfterFailure = true
    for issue in found { XCTFail(issue) }
  }

  /// The element an issue is about, as its identifier, label, title and frame.
  private static func name(_ element: XCUIElement?) -> String {
    guard let element else { return "no element" }
    guard element.exists else { return "an element since gone" }
    return "\(element.elementType) '\(element.identifier)' '\(element.label)' '\(element.title)' at \(element.frame)"
  }
}

/// Runs `XCUIApplication.performAccessibilityAudit()` on every screen the
/// UI-test harness can reach without the setup-complete flag: the setup
/// wizard, the API-key sheet, every Settings pane and its sheets, the Reset
/// confirmation, and the menu bar menu.
final class AccessibilityAuditUITests: BlurtUITestCase {
  /// The setup wizard, before and after a key is saved, and the key sheet.
  func testSetupWizard() throws {
    var found: [String] = []
    let main = mainWindow()
    try audit("wizard, no key", into: &found)

    let connect = main.buttons[UITestIdentifiers.apiKeyConnect]
    if connect.waitForExistence(timeout: 5) {
      connect.click()
      let sheet = main.sheets.firstMatch
      XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The API key sheet should open")
      try audit("wizard, API key sheet", into: &found)
      // Saved through the sheet, as a user would: the harness is closed by
      // now (`mainWindow()` closes its siblings).
      let field = sheet.secureTextFields[UITestIdentifiers.apiKeyField]
      field.click()
      field.typeText(UITestIdentifiers.validAPIKey)
      sheet.buttons[UITestIdentifiers.apiKeySave].click()
      XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Saving a valid key should close the sheet")
    } else {
      found.append("[wizard] no Connect button to open the key sheet:\n\(main.debugDescription)")
    }
    try audit("wizard, key saved", into: &found)
    assertNoAccessibilityIssues(found)
  }

  /// Every Settings pane, in toolbar order.
  func testSettingsPanes() throws {
    var found: [String] = []
    var settings = openSettingsWindow()
    try audit("Settings › General", into: &found)
    for pane in [
      UITestIdentifiers.keysSettingsTab, UITestIdentifiers.soundsSettingsTab, UITestIdentifiers.readAloudSettingsTab,
      UITestIdentifiers.stylesSettingsTab, UITestIdentifiers.vocabularySettingsTab,
      UITestIdentifiers.advancedSettingsTab,
    ] {
      settings = selectSettingsTab(settings, named: pane)
      try audit("Settings › \(pane)", into: &found)
    }
    assertNoAccessibilityIssues(found)
  }

  /// The sheets and the alert the Settings panes open: the API key, a new
  /// style, a new text shortcut, and Reset's confirmation.
  func testSettingsSheets() throws {
    var found: [String] = []
    let general = openSettingsWindow()
    general.buttons[UITestIdentifiers.apiKeyConnect].click()
    let keySheet = general.sheets.firstMatch
    XCTAssertTrue(keySheet.waitForExistence(timeout: 5), "The API key sheet should open")
    try audit("Settings › General › API key sheet", into: &found)
    keySheet.buttons[UITestIdentifiers.apiKeyCancel].click()
    XCTAssertTrue(keySheet.waitForNonExistence(timeout: 5))

    let styles = selectSettingsTab(general, named: UITestIdentifiers.stylesSettingsTab)
    styles.buttons[UITestIdentifiers.styleProfileAdd].click()
    let styleSheet = styles.sheets.firstMatch
    XCTAssertTrue(styleSheet.waitForExistence(timeout: 5), "The Add Style sheet should open")
    try audit("Settings › Styles › Add Style sheet", into: &found)
    styleSheet.buttons[UITestIdentifiers.styleProfileCancel].click()
    XCTAssertTrue(styleSheet.waitForNonExistence(timeout: 5))

    let vocabulary = selectSettingsTab(styles, named: UITestIdentifiers.vocabularySettingsTab)
    vocabulary.buttons[UITestIdentifiers.textShortcutAdd].click()
    let shortcutSheet = vocabulary.sheets.firstMatch
    XCTAssertTrue(shortcutSheet.waitForExistence(timeout: 5), "The text shortcut sheet should open")
    try audit("Settings › Vocabulary › text shortcut sheet", into: &found)
    shortcutSheet.buttons[UITestIdentifiers.textShortcutCancel].click()
    XCTAssertTrue(shortcutSheet.waitForNonExistence(timeout: 5))

    let advanced = selectSettingsTab(vocabulary, named: UITestIdentifiers.advancedSettingsTab)
    advanced.anyDescendant(identified: UITestIdentifiers.installReset).click()
    // Off `app`: a SwiftUI `.alert` isn't necessarily a sheet of its window.
    XCTAssertTrue(app.staticTexts["Reset Blurt?"].waitForExistence(timeout: 5), "Reset should ask first")
    try audit("Settings › Advanced › Reset confirmation", into: &found)
    // Scoped to the alert: an app-level "Cancel" also matches the Touch Bar's.
    if let confirmation = [app.sheets.firstMatch, app.dialogs.firstMatch].first(where: { $0.exists }) {
      confirmation.buttons["Cancel"].click()
    } else {
      app.typeKey(.escape, modifierFlags: [])
    }
    XCTAssertTrue(app.staticTexts["Reset Blurt?"].waitForNonExistence(timeout: 5), "Cancel should close Reset")
    assertNoAccessibilityIssues(found)
  }

  /// The menu bar status item's menu, open.
  func testMenuBarMenu() throws {
    var found: [String] = []
    let statusItem = app.menuBars.statusItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 15), "Blurt menu bar status item never appeared")
    statusItem.click()
    XCTAssertTrue(app.menuItems["Open Blurt"].waitForExistence(timeout: 5))
    try audit("menu bar menu", into: &found)
    app.typeKey(.escape, modifierFlags: [])
    assertNoAccessibilityIssues(found)
  }
}

/// The screens behind setup: the ready screen with an empty Library.
final class ReadyAccessibilityAuditUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] { [UITestIdentifiers.readyLaunchArgument] }

  func testReadyScreenEmptyLibrary() throws {
    var found: [String] = []
    mainWindow()
    try audit("ready, empty Library", into: &found)
    assertNoAccessibilityIssues(found)
  }

  /// The overlay pill while recording, and while reading aloud.
  func testOverlayPill() throws {
    var found: [String] = []
    let pill = app.anyDescendant(identified: UITestIdentifiers.overlayPill)
    let harness = readyHarness()
    harness.buttons[UITestIdentifiers.startButton].click()
    waitForLabel(pill, equals: "Recording.", "The pill should show the recording")
    try audit("overlay pill, recording", into: &found)
    harness.buttons[UITestIdentifiers.cancelButton].click()
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusIdle)

    startRead(in: harness)
    waitForLabel(pill, equals: "Reading aloud.", "The pill should show the read")
    try audit("overlay pill, reading aloud", into: &found)
    assertNoAccessibilityIssues(found)
  }
}

/// The Library with entries, and an open transcript in each of its views.
final class LibraryAccessibilityAuditUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] {
    [UITestIdentifiers.readyLaunchArgument, UITestIdentifiers.seedHistoryLaunchArgument]
  }

  func testLibraryAndTranscriptPage() throws {
    var found: [String] = []
    mainWindow()
    let recording = row(titled: UITestIdentifiers.seededRecordingTitle)
    XCTAssertTrue(recording.waitForExistence(timeout: 10))
    // The toolbar's icon-only menus say what they are, not what their symbol
    // is called (VoiceOver read the View menu as "Sparkle").
    let filter = app.windows[UITestIdentifiers.mainWindowTitle].menuButtons[UITestIdentifiers.libraryFilterMenu]
    XCTAssertEqual(filter.label, "Filter")
    try audit("Library, seeded", into: &found)

    recording.doubleClick()
    XCTAssertTrue(viewPicker.waitForExistence(timeout: 5), "The transcript page should open")
    XCTAssertEqual(viewPicker.label, "View")
    try audit("transcript page, Full", into: &found)
    showView("Plain text")
    try audit("transcript page, Plain text", into: &found)
    showView("Meeting notes")
    XCTAssertTrue(
      app.descendants(matching: .any)
        .matching(
          NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", UITestIdentifiers.cannedTaskResult,
            UITestIdentifiers.cannedTaskResult)
        ).firstMatch.waitForExistence(timeout: 10))
    try audit("transcript page, Meeting notes", into: &found)
    assertNoAccessibilityIssues(found)
  }
}
