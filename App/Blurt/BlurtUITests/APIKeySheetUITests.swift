import XCTest

/// Drives the AssemblyAI API-key sheet reached from the Settings window's
/// account row: connect, reject, unreachable, reveal, an edit clearing the
/// error, "Get a Free Key" only before a key is stored, change and cancel, and
/// a key connected in Settings reaching the setup window. All offline — the
/// submit is short-circuited in UI-test mode, so these never reach AssemblyAI
/// or the real Keychain.
final class APIKeySheetUITests: BlurtUITestCase {
  /// Connecting a key dismisses the sheet and leaves the row showing the stored
  /// key's masked tail plus the "Change…" affordance.
  func testConnectingAPIKeyShowsMaskedRow() {
    let settings = openSettingsWindow()
    let sheet = openKeyEditor(settings)

    typeKey(UITestIdentifiers.validAPIKey, into: sheet)
    sheet.buttons[UITestIdentifiers.apiKeySave].click()

    XCTAssertTrue(
      sheet.waitForNonExistence(timeout: 10),
      "A verified key should dismiss the sheet"
    )
    let saved = settings.staticTexts[UITestIdentifiers.apiKeySavedStatus]
    XCTAssertTrue(
      saved.waitForExistence(timeout: 5),
      "A verified key should leave the row connected"
    )
    XCTAssertTrue(
      settings.buttons[UITestIdentifiers.apiKeyChange].exists,
      "The row button should become Change… once a key is stored"
    )
    XCTAssertFalse(
      settings.staticTexts[UITestIdentifiers.apiKeyNotConnected].exists,
      "The row should no longer read Not connected"
    )
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
      "A rejected key should show the inline error in the sheet"
    )
    XCTAssertTrue(sheet.exists, "A rejected key should leave the sheet open to retry")
    XCTAssertFalse(settings.staticTexts[UITestIdentifiers.apiKeySavedStatus].exists)
  }

  /// "Show key" swaps the secure field for a plain text field so the user can
  /// read back a pasted key.
  func testShowKeyTogglesSecureField() {
    let settings = openSettingsWindow()
    let sheet = openKeyEditor(settings)

    XCTAssertTrue(
      sheet.secureTextFields[UITestIdentifiers.apiKeyField].waitForExistence(timeout: 5)
    )
    sheet.checkBoxes[UITestIdentifiers.apiKeyReveal].click()

    XCTAssertTrue(
      sheet.textFields[UITestIdentifiers.apiKeyField].waitForExistence(timeout: 5),
      "Show key should expose a plain (non-secure) text field"
    )
  }

  /// A server that can't be reached is a retry, not a verdict on the key: the
  /// sheet stays open with the inline error, and nothing is stored.
  func testUnreachableServerShowsInlineErrorAndStoresNothing() {
    let settings = openSettingsWindow()
    let sheet = openKeyEditor(settings)

    typeKey(UITestIdentifiers.unreachableAPIKey, into: sheet)
    sheet.buttons[UITestIdentifiers.apiKeySave].click()

    XCTAssertTrue(
      sheet.staticTexts[UITestIdentifiers.apiKeyError].waitForExistence(timeout: 10),
      "An unreachable server should show the inline error in the sheet"
    )
    sheet.buttons[UITestIdentifiers.apiKeyCancel].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Cancel should dismiss the sheet")
    XCTAssertTrue(
      settings.buttons[UITestIdentifiers.apiKeyConnect].waitForExistence(timeout: 5),
      "An unverified key must not be stored: the row should still offer to connect"
    )
    XCTAssertFalse(settings.staticTexts[UITestIdentifiers.apiKeySavedStatus].exists)
  }

  /// The inline error describes the key that was submitted, so editing the
  /// field clears it rather than leaving it under a key it no longer describes.
  func testEditingTheKeyClearsTheError() {
    let sheet = openKeyEditor(openSettingsWindow())
    typeKey(UITestIdentifiers.invalidAPIKey, into: sheet)
    sheet.buttons[UITestIdentifiers.apiKeySave].click()
    let error = sheet.staticTexts[UITestIdentifiers.apiKeyError]
    XCTAssertTrue(error.waitForExistence(timeout: 10), "A rejected key should show the inline error")

    typeKey("x", into: sheet)

    XCTAssertTrue(error.waitForNonExistence(timeout: 5), "Editing the key should clear the error")
  }

  /// "Get a Free Key" is offered only while no key is stored: once one is, the
  /// user has clearly found the dashboard, and rotating doesn't need the link.
  /// (Not clicked — it opens the browser.)
  func testGetAFreeKeyIsOfferedOnlyBeforeAKeyIsStored() {
    let settings = openSettingsWindow()
    let first = openKeyEditor(settings)
    XCTAssertTrue(
      first.buttons[UITestIdentifiers.apiKeyGetKey].waitForExistence(timeout: 5),
      "A first connect should offer the link to get a key"
    )
    first.buttons[UITestIdentifiers.apiKeyCancel].click()
    XCTAssertTrue(first.waitForNonExistence(timeout: 5), "Cancel should dismiss the sheet")

    connectValidKey(settings)
    let rotating = openKeyEditor(settings, via: UITestIdentifiers.apiKeyChange)
    XCTAssertTrue(rotating.buttons[UITestIdentifiers.apiKeySave].waitForExistence(timeout: 5))
    XCTAssertFalse(
      rotating.buttons[UITestIdentifiers.apiKeyGetKey].exists,
      "Rotating a stored key shouldn't offer the link to get one"
    )
  }

  /// Settings and the setup window host the same section, so a key connected
  /// in one reaches the other's row rather than leaving it "Not connected".
  func testKeyConnectedInSettingsReachesTheSetupWindow() {
    connectValidKey(openSettingsWindow())

    let setup = mainWindow()
    XCTAssertTrue(
      setup.staticTexts[UITestIdentifiers.apiKeySavedStatus].waitForExistence(timeout: 10),
      "The setup window's row should show the key connected in Settings"
    )
    XCTAssertFalse(setup.staticTexts[UITestIdentifiers.apiKeyNotConnected].exists)
  }

  /// After a key is stored, "Change…" re-opens the sheet so it can be rotated.
  func testChangeReopensEditorAfterConnecting() {
    let settings = openSettingsWindow()
    connectValidKey(settings)

    let reopened = openKeyEditor(settings, via: UITestIdentifiers.apiKeyChange)
    XCTAssertTrue(
      reopened.secureTextFields[UITestIdentifiers.apiKeyField].waitForExistence(timeout: 5),
      "Change… should re-open the sheet on the key field"
    )
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
      "Cancel should return to the connected row"
    )
  }
}
