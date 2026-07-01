import XCTest

/// Drives the Settings window: the AssemblyAI API-key flow (save / reject), the
/// dictation-key picker, the sound-cue picker, and the key-terms field. All
/// offline — the API-key submit is short-circuited in UI-test mode, so these
/// never reach AssemblyAI or the real Keychain.
final class SettingsUITests: BlurtUITestCase {
  /// Saving a key collapses the editable field to the "✓ Saved" status row.
  func testSavingAPIKeyCollapsesToSavedRow() {
    let settings = openSettingsWindow()

    let field = settings.secureTextFields[UITestIDs.apiKeyField]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "API key field not found")
    field.click()
    field.typeText("a-valid-looking-key")

    settings.buttons[UITestIDs.apiKeySave].click()

    let saved = settings.staticTexts[UITestIDs.apiKeySavedStatus]
    XCTAssertTrue(
      saved.waitForExistence(timeout: 10),
      "Saving a valid key should collapse to the Saved status row")
    // The "Change" affordance replaces the editable field once a key is stored.
    XCTAssertTrue(settings.buttons[UITestIDs.apiKeyChange].exists)
  }

  /// A rejected key surfaces an inline error instead of collapsing.
  func testRejectedAPIKeyShowsInlineError() {
    let settings = openSettingsWindow()

    let field = settings.secureTextFields[UITestIDs.apiKeyField]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.click()
    field.typeText(UITestIDs.invalidAPIKey)

    settings.buttons[UITestIDs.apiKeySave].click()

    let error = settings.staticTexts[UITestIDs.apiKeyError]
    XCTAssertTrue(
      error.waitForExistence(timeout: 10),
      "A rejected key should show the inline error footer")
    // It must NOT have collapsed to the saved row.
    XCTAssertFalse(settings.staticTexts[UITestIDs.apiKeySavedStatus].exists)
  }

  /// The reveal toggle swaps the secure field for a plain text field so the
  /// user can read back a pasted key.
  func testRevealTogglesSecureField() {
    let settings = openSettingsWindow()

    XCTAssertTrue(
      settings.secureTextFields[UITestIDs.apiKeyField].waitForExistence(timeout: 10))
    settings.buttons[UITestIDs.apiKeyReveal].click()

    XCTAssertTrue(
      settings.textFields[UITestIDs.apiKeyField].waitForExistence(timeout: 5),
      "Revealing should expose a plain (non-secure) text field")
  }

  /// The dictation-key picker changes the persisted trigger selection.
  func testHotkeyPickerChangesSelection() {
    let settings = openSettingsWindow()

    let picker = settings.popUpButtons[UITestIDs.hotkeyPicker]
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

    let picker = settings.popUpButtons[UITestIDs.soundPicker]
    XCTAssertTrue(picker.waitForExistence(timeout: 10), "Sound picker not found")
    picker.click()
    app.menuItems["None"].click()

    XCTAssertEqual(picker.value as? String, "None", "Choosing None should stick as the selection")
  }

  /// After a key is saved, "Change" re-opens the editable field so the key can
  /// be rotated.
  func testChangeReopensEditableFieldAfterSaving() {
    let settings = openSettingsWindow()

    let field = settings.secureTextFields[UITestIDs.apiKeyField]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "API key field not found")
    field.click()
    field.typeText("a-valid-looking-key")
    settings.buttons[UITestIDs.apiKeySave].click()

    let change = settings.buttons[UITestIDs.apiKeyChange]
    XCTAssertTrue(
      change.waitForExistence(timeout: 10),
      "Saving should collapse to the row with a Change button")
    change.click()

    XCTAssertTrue(
      settings.secureTextFields[UITestIDs.apiKeyField].waitForExistence(timeout: 5),
      "Change should re-open the editable key field")
  }

  /// "Cancel" while changing a saved key discards the edit and restores the
  /// "✓ Saved" row instead of committing.
  func testCancelDiscardsKeyEditAndRestoresSavedRow() {
    let settings = openSettingsWindow()

    let field = settings.secureTextFields[UITestIDs.apiKeyField]
    XCTAssertTrue(field.waitForExistence(timeout: 10), "API key field not found")
    field.click()
    field.typeText("a-valid-looking-key")
    settings.buttons[UITestIDs.apiKeySave].click()

    let change = settings.buttons[UITestIDs.apiKeyChange]
    XCTAssertTrue(change.waitForExistence(timeout: 10), "Saving should offer a Change button")
    change.click()

    let cancel = settings.buttons[UITestIDs.apiKeyCancel]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Change should expose a Cancel button")
    cancel.click()

    XCTAssertTrue(
      settings.staticTexts[UITestIDs.apiKeySavedStatus].waitForExistence(timeout: 5),
      "Cancel should restore the ✓ Saved row")
    XCTAssertFalse(
      settings.secureTextFields[UITestIDs.apiKeyField].exists,
      "Cancel should hide the editable key field")
  }
}
