import XCTest

/// Drives the Settings window: the AssemblyAI API-key sheet (connect / reject
/// / cancel) reached from the account row, the
/// dictation-key picker, the sound-cue picker, and the key-terms field. All
/// offline — the API-key submit is short-circuited in UI-test mode, so these
/// never reach AssemblyAI or the real Keychain.
final class SettingsUITests: BlurtUITestCase {
  /// Connecting a key dismisses the sheet and leaves the row showing the stored
  /// key's masked tail plus the "Change…" affordance.
  func testConnectingAPIKeyShowsMaskedRow() {
    let settings = openSettingsWindow()
    let sheet = openKeyEditor(settings)

    typeKey(UITestIdentifiers.validAPIKey, into: sheet)
    sheet.buttons[UITestIdentifiers.apiKeySave].click()

    XCTAssertTrue(
      sheet.waitForNonExistence(timeout: 10),
      "A verified key should dismiss the sheet")
    let saved = settings.staticTexts[UITestIdentifiers.apiKeySavedStatus]
    XCTAssertTrue(
      saved.waitForExistence(timeout: 5),
      "A verified key should leave the row connected")
    XCTAssertTrue(
      settings.buttons[UITestIdentifiers.apiKeyChange].exists,
      "The row button should become Change… once a key is stored")
    XCTAssertFalse(
      settings.staticTexts[UITestIdentifiers.apiKeyNotConnected].exists,
      "The row should no longer read Not connected")
  }

  /// A rejected key keeps the sheet open and explains itself there, rather than
  /// dismissing or raising an alert.
  func testRejectedAPIKeyShowsInlineErrorInSheet() {
    let settings = openSettingsWindow()
    let sheet = openKeyEditor(settings)

    typeKey(UITestIdentifiers.invalidAPIKey, into: sheet)
    sheet.buttons[UITestIdentifiers.apiKeySave].click()

    let error = sheet.staticTexts[UITestIdentifiers.apiKeyError]
    XCTAssertTrue(
      error.waitForExistence(timeout: 10),
      "A rejected key should show the inline error in the sheet")
    XCTAssertTrue(sheet.exists, "A rejected key should leave the sheet open to retry")
    XCTAssertFalse(settings.staticTexts[UITestIdentifiers.apiKeySavedStatus].exists)
  }

  /// "Show key" swaps the secure field for a plain text field so the user can
  /// read back a pasted key.
  func testShowKeyTogglesSecureField() {
    let settings = openSettingsWindow()
    let sheet = openKeyEditor(settings)

    XCTAssertTrue(
      sheet.secureTextFields[UITestIdentifiers.apiKeyField].waitForExistence(timeout: 5))
    sheet.checkBoxes[UITestIdentifiers.apiKeyReveal].click()

    XCTAssertTrue(
      sheet.textFields[UITestIdentifiers.apiKeyField].waitForExistence(timeout: 5),
      "Show key should expose a plain (non-secure) text field")
  }

  /// The dictation-key picker changes the persisted trigger selection.
  func testHotkeyPickerChangesSelection() {
    let settings = openSettingsWindow()

    let picker = settings.popUpButtons[UITestIdentifiers.hotkeyPicker]
    XCTAssertTrue(picker.waitForExistence(timeout: 10), "Hotkey picker not found")
    // Default is right ⌘; switch to right ⌥ and confirm the selection sticks.
    picker.click()
    app.menuItems["right ⌥"].click()

    XCTAssertEqual(picker.value as? String, "right ⌥")
  }

  /// The sound-cue picker changes the persisted selection. Selecting "None"
  /// works regardless of the runner's persisted starting value.
  func testSoundPickerChangesSelection() {
    let settings = openSettingsWindow()

    let picker = settings.popUpButtons[UITestIdentifiers.soundPicker]
    XCTAssertTrue(picker.waitForExistence(timeout: 10), "Sound picker not found")
    picker.click()
    app.menuItems["None"].click()

    XCTAssertEqual(picker.value as? String, "None", "Choosing None should stick as the selection")
  }

  /// Developer mode starts off (the UI-test launch resets persisted settings)
  /// and a click switches it on. Matched by identifier rather than element type
  /// so the test doesn't care whether AppKit exposes the SwiftUI switch as a
  /// switch or a checkbox. The toggle lives on the Advanced pane, so switch to
  /// that tab first.
  func testDeveloperModeTogglesOn() {
    let settings = openSettingsWindow()
    let advanced = selectSettingsTab(settings, named: UITestIdentifiers.advancedSettingsTab)

    let toggle = advanced.anyDescendant(identified: UITestIdentifiers.developerToggle)
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Developer mode toggle not found")
    XCTAssertEqual("\(toggle.value ?? "")", "0", "Developer mode should start switched off")

    toggle.click()

    XCTAssertEqual("\(toggle.value ?? "")", "1", "Clicking should switch developer mode on")
  }

  /// The Advanced pane's "Check for Updates" button runs the check and reports
  /// the result in a modal. Under UI testing the check is stubbed offline to
  /// always report up-to-date, so clicking it surfaces the "You’re up to date"
  /// result sheet deterministically (no network).
  func testCheckForUpdatesShowsResultAlert() {
    let settings = openSettingsWindow()
    let advanced = selectSettingsTab(settings, named: UITestIdentifiers.advancedSettingsTab)

    let button = advanced.anyDescendant(identified: UITestIdentifiers.updateCheck)
    XCTAssertTrue(button.waitForExistence(timeout: 10), "Check for Updates button not found")
    button.click()

    let alert = app.sheets.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 10), "The check should present a result sheet")
    XCTAssertTrue(
      alert.staticTexts["You’re up to date"].exists,
      "The stubbed check should report up to date")
    alert.buttons["OK"].click()
  }

  /// The Advanced pane's reset button asks first, and Cancel leaves the install
  /// exactly as it was — the stored key is still connected afterwards.
  ///
  /// The *confirming* path is deliberately not exercised: it revokes the app's
  /// TCC grants and restarts Blurt, so an automated click of it would take the
  /// runner's machine (and the rest of the suite) with it. What a confirmed
  /// reset does is covered where it lives, over doubles — the engine's
  /// `InstallResetTests`.
  func testResetAsksBeforeDoingAnything() {
    let settings = openSettingsWindow()
    connectValidKey(settings)
    let advanced = selectSettingsTab(settings, named: UITestIdentifiers.advancedSettingsTab)

    let button = advanced.anyDescendant(identified: UITestIdentifiers.installReset)
    XCTAssertTrue(button.waitForExistence(timeout: 10), "Reset button not found")
    button.click()

    // Queried off `app`, not off the settings window: a SwiftUI `.alert` isn't
    // necessarily a sheet of the window it was declared in (the API-key
    // `.sheet` above is), so the confirmation is identified by the words on it
    // wherever AppKit chose to put it.
    let confirmationTitle = app.staticTexts["Reset Blurt?"]
    XCTAssertTrue(
      confirmationTitle.waitForExistence(timeout: 10),
      "Reset should ask for confirmation rather than acting on the click")
    XCTAssertTrue(
      app.buttons["Reset and Restart"].exists,
      "The confirmation should say that Blurt restarts when the reset finishes")
    // Dismissed with Escape, not by clicking "Cancel": this test opened the
    // API-key sheet earlier and its own Cancel is still in the accessibility
    // tree, so an app-level query for that title matches more than one element.
    // Escape is what the `.cancel` role binds, so it exercises the same button.
    app.typeKey(.escape, modifierFlags: [])

    XCTAssertTrue(
      confirmationTitle.waitForNonExistence(timeout: 5),
      "Escape should dismiss the confirmation without resetting anything")

    // Reopened rather than reused: an unmodified Escape falls through to the
    // window behind the alert, so the settings window may have closed with it.
    // What this assertion is about is the stored key, not which window survived
    // the keystroke — and `openSettingsWindow` no-ops when one is still up.
    let general = selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.generalSettingsTab)
    XCTAssertTrue(
      general.staticTexts[UITestIdentifiers.apiKeySavedStatus].waitForExistence(timeout: 5),
      "Dismissing the confirmation should leave the stored key alone")
  }

  /// After a key is stored, "Change…" re-opens the sheet so it can be rotated.
  func testChangeReopensEditorAfterConnecting() {
    let settings = openSettingsWindow()
    connectValidKey(settings)

    let reopened = openKeyEditor(settings, via: UITestIdentifiers.apiKeyChange)
    XCTAssertTrue(
      reopened.secureTextFields[UITestIdentifiers.apiKeyField].waitForExistence(timeout: 5),
      "Change… should re-open the sheet on the key field")
  }

  /// "Cancel" in the sheet discards the edit and leaves the stored key's row
  /// untouched instead of committing.
  func testCancelDiscardsKeyEditAndKeepsRow() {
    let settings = openSettingsWindow()
    connectValidKey(settings)

    let sheet = openKeyEditor(settings, via: UITestIdentifiers.apiKeyChange)
    sheet.buttons[UITestIdentifiers.apiKeyCancel].click()

    // Dismissal is asynchronous, so wait it out rather than asserting on
    // `exists` in the same run-loop turn as the click.
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Cancel should dismiss the sheet")
    XCTAssertTrue(
      settings.staticTexts[UITestIdentifiers.apiKeySavedStatus].waitForExistence(timeout: 5),
      "Cancel should return to the connected row")
  }

  // MARK: - API-key helpers

  /// Opens the API-key sheet from the settings row and returns it. `identifier`
  /// picks the row button by its state: "Connect…" before a key exists,
  /// "Change…" once one is stored.
  private func openKeyEditor(
    _ settings: XCUIElement,
    via identifier: String = UITestIdentifiers.apiKeyConnect
  ) -> XCUIElement {
    let button = settings.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: 10), "API key row button (\(identifier)) not found")
    button.click()
    let sheet = settings.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The API key sheet should open")
    return sheet
  }

  /// Types into the sheet's key field. The field is focused on open, but a click
  /// makes the target explicit rather than relying on default focus.
  private func typeKey(_ key: String, into sheet: XCUIElement) {
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
  private func connectValidKey(_ settings: XCUIElement) {
    let sheet = openKeyEditor(settings)
    typeKey(UITestIdentifiers.validAPIKey, into: sheet)
    sheet.buttons[UITestIdentifiers.apiKeySave].click()
    XCTAssertTrue(
      sheet.waitForNonExistence(timeout: 10),
      "Connecting a valid key should dismiss the sheet")
    XCTAssertTrue(
      settings.staticTexts[UITestIdentifiers.apiKeySavedStatus].waitForExistence(timeout: 5),
      "Connecting a valid key should show the connected row")
  }
}
