import XCTest

// DIAGNOSTIC PASS: audits every category and reports every issue, so the CI
// log says what each screen raises today. Replaced by the gated version once
// the findings are triaged.
private let auditedTypes: XCUIAccessibilityAuditType = .all

extension BlurtUITestCase {
  /// Audits the whole app as it stands, collecting each issue into `found`
  /// under `screen` rather than failing on the first, so one run names every
  /// issue on every screen a test visits. Issues raised by the UI-test
  /// harness's own window are skipped: it is test scaffolding, never shipped.
  func audit(_ screen: String, into found: inout [String]) throws {
    let harness = app.windows[UITestIdentifiers.harnessWindowTitle]
    let harnessFrame = harness.exists ? harness.frame : .null
    var issues: [String] = []
    try app.performAccessibilityAudit(for: auditedTypes) { issue in
      let element = issue.element
      if let element, element.exists, harnessFrame.contains(element.frame) { return true }
      issues.append(Self.describe(issue))
      return true
    }
    found += issues.map { "[\(screen)] \($0)" }
  }

  /// Fails once, listing every issue `found` holds.
  func assertNoAccessibilityIssues(_ found: [String]) {
    XCTAssertTrue(found.isEmpty, "\(found.count) accessibility issue(s):\n" + found.joined(separator: "\n"))
  }

  private static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
    let element = issue.element.map { element -> String in
      guard element.exists else { return "gone" }
      return
        "type=\(element.elementType.rawValue) id='\(element.identifier)' label='\(element.label)' "
        + "title='\(element.title)' value='\(String(describing: element.value))' frame=\(element.frame)"
    }
    return
      "\(name(of: issue.auditType)): \(issue.compactDescription) | \(issue.detailedDescription) | \(element ?? "no element")"
  }

  private static func name(of type: XCUIAccessibilityAuditType) -> String {
    let names: [(XCUIAccessibilityAuditType, String)] = [
      (.contrast, "contrast"), (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
      (.sufficientElementDescription, "sufficientElementDescription"), (.action, "action"),
      (.parentChild, "parentChild"),
    ]
    return names.first { type.contains($0.0) }?.1 ?? "type(\(type.rawValue))"
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
      sheet.buttons[UITestIdentifiers.apiKeyCancel].click()
      XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    } else {
      found.append("[wizard] no Connect button to open the key sheet:\n\(main.debugDescription)")
    }

    let harness = harnessWindow()
    harness.buttons[UITestIdentifiers.setKeyButton].click()
    mainWindow()
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
    let confirmation = [app.sheets.firstMatch, app.dialogs.firstMatch].first { $0.exists }
    // Scoped to the alert: an app-level "Cancel" also matches the Touch Bar's.
    confirmation?.buttons["Cancel"].click()
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
    try audit("Library, seeded", into: &found)

    recording.doubleClick()
    XCTAssertTrue(viewPicker.waitForExistence(timeout: 5), "The transcript page should open")
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
