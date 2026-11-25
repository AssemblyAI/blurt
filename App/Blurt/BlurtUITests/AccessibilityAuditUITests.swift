import XCTest

/// Runs `XCUIApplication.performAccessibilityAudit()` on every screen the
/// UI-test harness can reach without the setup-complete flag: the setup
/// wizard, the API-key sheet, every Settings pane and its sheets, the Reset
/// confirmation, and the menu bar menu. (What the audit checks, and why the
/// rest is left out: `BlurtUITestCase+AccessibilityAudit.swift`.)
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

  /// The sheets and the alert the Settings panes open: the API key (and its
  /// inline error for a rejected key), a new style, a new text shortcut, and
  /// Reset's confirmation.
  func testSettingsSheets() throws {
    var found: [String] = []
    let general = openSettingsWindow()
    general.buttons[UITestIdentifiers.apiKeyConnect].click()
    let keySheet = general.sheets.firstMatch
    XCTAssertTrue(keySheet.waitForExistence(timeout: 5), "The API key sheet should open")
    try audit("Settings › General › API key sheet", into: &found)
    // A rejected key: the sheet stays open and explains itself inline.
    let field = keySheet.secureTextFields[UITestIdentifiers.apiKeyField]
    field.click()
    field.typeText(UITestIdentifiers.invalidAPIKey)
    keySheet.buttons[UITestIdentifiers.apiKeySave].click()
    XCTAssertTrue(
      keySheet.staticTexts[UITestIdentifiers.apiKeyError].waitForExistence(timeout: 10),
      "A rejected key should show the inline error in the sheet"
    )
    try audit("Settings › General › API key sheet, key rejected", into: &found)
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
    if let confirmation = [app.sheets.firstMatch, app.dialogs.firstMatch].first(where: \.exists) {
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
