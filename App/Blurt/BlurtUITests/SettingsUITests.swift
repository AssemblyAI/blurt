import XCTest

/// Drives the Settings window: the AssemblyAI API-key flow (save / reject), the
/// dictation-key picker, the sound-cue picker, and the key-terms field. All
/// offline — the API-key submit is short-circuited in UI-test mode, so these
/// never reach AssemblyAI or the real Keychain.
final class SettingsUITests: BlurtUITestCase {
  /// Saving a key collapses the editable field to the "✓ Saved" status row.
  func testSavingAPIKeyCollapsesToSavedRow() {
    let settings = openSettingsWindow()

    let field = settings.secureTextFields[UITestIdentifiers.apiKeyField]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "API key field not found")
    field.click()
    field.typeText("a-valid-looking-key")

    settings.buttons[UITestIdentifiers.apiKeySave].click()

    let saved = settings.staticTexts[UITestIdentifiers.apiKeySavedStatus]
    XCTAssertTrue(
      saved.waitForExistence(timeout: 10),
      "Saving a valid key should collapse to the Saved status row")
    // The "Change" affordance replaces the editable field once a key is stored.
    XCTAssertTrue(settings.buttons[UITestIdentifiers.apiKeyChange].exists)
  }

  /// A rejected key surfaces an inline error instead of collapsing.
  func testRejectedAPIKeyShowsInlineError() {
    let settings = openSettingsWindow()

    let field = settings.secureTextFields[UITestIdentifiers.apiKeyField]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.click()
    field.typeText(UITestIdentifiers.invalidAPIKey)

    settings.buttons[UITestIdentifiers.apiKeySave].click()

    let error = settings.staticTexts[UITestIdentifiers.apiKeyError]
    XCTAssertTrue(
      error.waitForExistence(timeout: 10),
      "A rejected key should show the inline error footer")
    // It must NOT have collapsed to the saved row.
    XCTAssertFalse(settings.staticTexts[UITestIdentifiers.apiKeySavedStatus].exists)
  }

  /// The reveal toggle swaps the secure field for a plain text field so the
  /// user can read back a pasted key.
  func testRevealTogglesSecureField() {
    let settings = openSettingsWindow()

    XCTAssertTrue(
      settings.secureTextFields[UITestIdentifiers.apiKeyField].waitForExistence(timeout: 10))
    settings.buttons[UITestIdentifiers.apiKeyReveal].click()

    XCTAssertTrue(
      settings.textFields[UITestIdentifiers.apiKeyField].waitForExistence(timeout: 5),
      "Revealing should expose a plain (non-secure) text field")
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

    let toggle = advanced.descendants(matching: .any)
      .matching(identifier: UITestIdentifiers.developerToggle).firstMatch
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

    let button = advanced.descendants(matching: .any)
      .matching(identifier: UITestIdentifiers.updateCheck).firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 10), "Check for Updates button not found")
    button.click()

    let alert = app.sheets.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 10), "The check should present a result sheet")
    XCTAssertTrue(
      alert.staticTexts["You’re up to date"].exists,
      "The stubbed check should report up to date")
    alert.buttons["OK"].click()
  }

  /// After a key is saved, "Change" re-opens the editable field so the key can
  /// be rotated.
  func testChangeReopensEditableFieldAfterSaving() {
    let settings = openSettingsWindow()

    let field = settings.secureTextFields[UITestIdentifiers.apiKeyField]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "API key field not found")
    field.click()
    field.typeText("a-valid-looking-key")
    settings.buttons[UITestIdentifiers.apiKeySave].click()

    let change = settings.buttons[UITestIdentifiers.apiKeyChange]
    XCTAssertTrue(
      change.waitForExistence(timeout: 10),
      "Saving should collapse to the row with a Change button")
    change.click()

    XCTAssertTrue(
      settings.secureTextFields[UITestIdentifiers.apiKeyField].waitForExistence(timeout: 5),
      "Change should re-open the editable key field")
  }

  /// "Cancel" while changing a saved key discards the edit and restores the
  /// "✓ Saved" row instead of committing.
  func testCancelDiscardsKeyEditAndRestoresSavedRow() {
    let settings = openSettingsWindow()

    let field = settings.secureTextFields[UITestIdentifiers.apiKeyField]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "API key field not found")
    field.click()
    field.typeText("a-valid-looking-key")
    settings.buttons[UITestIdentifiers.apiKeySave].click()

    let change = settings.buttons[UITestIdentifiers.apiKeyChange]
    XCTAssertTrue(change.waitForExistence(timeout: 10), "Saving should offer a Change button")
    change.click()

    let cancel = settings.buttons[UITestIdentifiers.apiKeyCancel]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Change should expose a Cancel button")
    cancel.click()

    XCTAssertTrue(
      settings.staticTexts[UITestIdentifiers.apiKeySavedStatus].waitForExistence(timeout: 5),
      "Cancel should restore the ✓ Saved row")
    XCTAssertFalse(
      settings.secureTextFields[UITestIdentifiers.apiKeyField].exists,
      "Cancel should hide the editable key field")
  }
}
