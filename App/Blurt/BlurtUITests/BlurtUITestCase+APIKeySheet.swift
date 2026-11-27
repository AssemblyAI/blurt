import XCTest

// Driving the AssemblyAI API-key sheet, for every suite that needs a key
// connected (or a sheet to test): opening it from the account row, typing a
// key, and the whole connect flow.
extension BlurtUITestCase {
  /// Opens the API-key sheet from the account row of `settings` (the Settings
  /// window, or the setup window, which hosts the same row) and returns it.
  /// `identifier` picks the row button by its state: "Connect…" before a key
  /// exists, "Change…" once one is stored.
  ///
  /// Waits for the button to be hittable, not just to exist: as the first test
  /// of a run, `testCancelDiscardsKeyEditAndKeepsRow` found Connect… present
  /// but covered, Settings having opened behind another window.
  /// `openSettingsWindow` now waits for Settings to be in front, so the row is
  /// never raised a second time here; a row still covered fails naming every
  /// window front to back, so the miss says what was on top.
  func openKeyEditor(
    _ settings: XCUIElement,
    via identifier: String = UITestIdentifiers.apiKeyConnect
  ) -> XCUIElement {
    let button = settings.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: 10), "API key row button (\(identifier)) not found")
    XCTAssertTrue(
      button.wait(for: \.isHittable, toEqual: true, timeout: 10),
      "API key row button (\(identifier)) is covered (at \(button.frame)); windows, front first: \(windowFrames())"
    )
    button.click()
    let sheet = settings.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The API key sheet should open")
    return sheet
  }

  /// Types into the sheet's key field. The field is focused on open, but a click
  /// makes the target explicit rather than relying on default focus.
  func typeKey(_ key: String, into sheet: XCUIElement) {
    let field = sheet.secureTextFields[UITestIdentifiers.apiKeyField]
    XCTAssertTrue(field.waitForExistence(timeout: 5), "API key field not found in the sheet")
    field.click()
    field.typeText(key)
  }

  /// Drives the whole connect flow so tests about the *stored* state don't each
  /// repeat it.
  ///
  /// Waits on the sheet's *disappearance*, not on the connected row's text: the
  /// row sits behind the sheet and is already on screen when it's still modal,
  /// so using it as the done signal lets the next step click a row button
  /// through a live sheet.
  func connectValidKey(_ settings: XCUIElement) {
    let sheet = openKeyEditor(settings)
    typeKey(UITestIdentifiers.validAPIKey, into: sheet)
    sheet.buttons[UITestIdentifiers.apiKeySave].click()
    XCTAssertTrue(
      sheet.waitForNonExistence(timeout: 10),
      "Connecting a valid key should dismiss the sheet"
    )
    XCTAssertTrue(
      settings.staticTexts[UITestIdentifiers.apiKeySavedStatus].waitForExistence(timeout: 5),
      "Connecting a valid key should show the connected row"
    )
  }
}
