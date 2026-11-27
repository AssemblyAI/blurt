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
  /// Waits for the button to be hittable, not just to exist. As the first test
  /// of a run, `testCancelDiscardsKeyEditAndKeepsRow` found Connect… covered by
  /// macOS's "Keystroke Receiving" prompt, which the app's real key tap raised
  /// at launch (PR #451's screenshot); the app makes no real tap under UI
  /// testing now (`DictationKeyTap.ensureRunning`), so nothing raises the row a
  /// second time here. A row still covered fails naming the app's state and
  /// every window front first, with a screenshot of the whole screen.
  func openKeyEditor(
    _ settings: XCUIElement,
    via identifier: String = UITestIdentifiers.apiKeyConnect
  ) -> XCUIElement {
    let button = settings.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: 10), "API key row button (\(identifier)) not found")
    let hittable = button.wait(for: \.isHittable, toEqual: true, timeout: 10)
    if !hittable {
      // What covers it is outside the app's own windows when Settings is in
      // front and the button inside it (a system prompt, last time), so the
      // whole screen is kept, and whether the app is the active one.
      let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
      screen.name = "screen with \(identifier) covered"
      screen.lifetime = .keepAlways
      add(screen)
    }
    XCTAssertTrue(
      hittable,
      "API key row button (\(identifier)) is covered (at \(button.frame)); app state \(app.state.rawValue) "
        + "(4 = in front); windows, front first: \(windowFrames())"
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
