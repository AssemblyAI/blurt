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
  /// but covered on every attempt. A covered Settings row is raised again with
  /// ⌘, (as `openSettingsWindow` does), and a row still covered fails naming
  /// every window's frame, so the next miss says what was on top.
  func openKeyEditor(
    _ settings: XCUIElement,
    via identifier: String = UITestIdentifiers.apiKeyConnect
  ) -> XCUIElement {
    let button = settings.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: 10), "API key row button (\(identifier)) not found")
    if !waitUntilHittable(button, timeout: 5), settings.title != UITestIdentifiers.mainWindowTitle {
      app.typeKey(",", modifierFlags: .command)
    }
    XCTAssertTrue(
      waitUntilHittable(button, timeout: 10),
      "API key row button (\(identifier)) is covered (at \(button.frame)); windows: \(windowFrames())"
    )
    button.click()
    let sheet = settings.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The API key sheet should open")
    return sheet
  }

  /// Whether `element` becomes hittable within `timeout`.
  private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
    return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
  }

  /// Every app window's title and frame, for a failure message.
  private func windowFrames() -> String {
    (0..<app.windows.count)
      .map { app.windows.element(boundBy: $0) }
      .map { "\($0.title) \($0.frame)" }
      .joined(separator: "; ")
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
