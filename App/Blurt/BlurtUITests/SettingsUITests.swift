import XCTest

/// Drives the Settings window: the AssemblyAI API-key sheet (connect / reject
/// / cancel) reached from the account row, the Keys tab, the Read Aloud tab,
/// the sound-cue pickers, and the key-terms field. All
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

  /// Taking the bound key off dictation moves the binding to the other dictating
  /// key: turn right ⌥ on, set right ⌘ to read aloud, and both stick.
  func testDictationMovesToAnotherKey() {
    let keys = openKeys()
    let option = keys.popUpButtons[UITestIdentifiers.keyStylePicker(rightOption)]
    let command = keys.popUpButtons[UITestIdentifiers.keyStylePicker(rightCommand)]

    option.click()
    app.menuItems["Dictate"].click()
    command.click()
    app.menuItems[KeyActionName.readAloud].click()

    XCTAssertEqual(command.value as? String, KeyActionName.readAloud)
    XCTAssertEqual(option.value as? String, "Dictate")
  }

  /// The microphone picker exists and defaults to following the system input.
  /// Only the first option is asserted: the rest of the menu lists whatever
  /// input devices the machine happens to have (a CI runner may have none), and
  /// the parenthetical default-device name varies with it — so the assertion is
  /// a prefix, and nothing here opens the menu or pins a device.
  func testMicrophonePickerDefaultsToSystemInput() {
    let settings = openSettingsWindow()

    let picker = settings.popUpButtons[UITestIdentifiers.micPicker]
    XCTAssertTrue(picker.waitForExistence(timeout: 10), "Microphone picker not found")
    let value = picker.value as? String ?? ""
    XCTAssertTrue(
      value.hasPrefix("Same as system"),
      "The picker should start on the system default (got: \(value))")
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

  /// UI-test builds are debug builds, which never start the Sparkle updater (a
  /// dev build must not overwrite itself with the release the appcast
  /// describes). The Updates section still renders, with its controls disabled
  /// rather than offering a check that could never run.
  func testUpdateControlsAreDisabledInDebugBuilds() {
    let settings = openSettingsWindow()
    let advanced = selectSettingsTab(settings, named: UITestIdentifiers.advancedSettingsTab)

    let button = advanced.anyDescendant(identified: UITestIdentifiers.updateCheck)
    XCTAssertTrue(button.waitForExistence(timeout: 10), "Check for Updates button not found")
    XCTAssertFalse(button.isEnabled, "A debug build's updater never starts, so the check is disabled")

    let autoCheck = advanced.anyDescendant(identified: UITestIdentifiers.updateAutoCheck)
    XCTAssertTrue(autoCheck.waitForExistence(timeout: 10), "Automatic-check toggle not found")
    XCTAssertFalse(autoCheck.isEnabled, "A debug build's update preferences are disabled")
  }

  /// The Advanced pane's reset button asks first, and dismissing the
  /// confirmation leaves the install exactly as it was.
  ///
  /// Everything happens on the Advanced pane, against the developer-mode switch
  /// — one of the settings `PersistedSettings.resetAll` clears — so "nothing was
  /// reset" is observable without switching tabs or opening the API-key sheet.
  /// That isn't tidiness: the sheet leaves its own "Cancel" in the accessibility
  /// tree, which made an app-level query for the alert's Cancel ambiguous, and
  /// dismissing with Escape instead closed the settings window along with the
  /// alert and took the follow-up assertions with it.
  ///
  /// The *confirming* path is deliberately not exercised: it revokes the app's
  /// TCC grants and restarts Blurt, so an automated click of it would take the
  /// runner's machine (and the rest of the suite) with it. What a confirmed
  /// reset does is covered where it lives, over doubles — the engine's
  /// `InstallResetTests`.
  func testResetAsksBeforeDoingAnything() {
    let settings = openSettingsWindow()
    let advanced = selectSettingsTab(settings, named: UITestIdentifiers.advancedSettingsTab)

    // Switch on a setting the sweep would clear, so a reset that ran anyway is
    // visible in the same pane. (The UI-test launch resets persisted settings,
    // so this starts off.)
    let developerMode = advanced.anyDescendant(identified: UITestIdentifiers.developerToggle)
    XCTAssertTrue(developerMode.waitForExistence(timeout: 10), "Developer mode toggle not found")
    developerMode.click()
    XCTAssertEqual("\(developerMode.value ?? "")", "1", "Clicking should switch developer mode on")

    let reset = advanced.anyDescendant(identified: UITestIdentifiers.installReset)
    XCTAssertTrue(reset.waitForExistence(timeout: 10), "Reset button not found")
    reset.click()

    // Queried off `app`, not off the settings window: a SwiftUI `.alert` isn't
    // necessarily a sheet of the window it was declared in, so the confirmation
    // is identified by the words on it wherever AppKit chose to put it.
    let confirmationTitle = app.staticTexts["Reset Blurt?"]
    XCTAssertTrue(
      confirmationTitle.waitForExistence(timeout: 10),
      "Reset should ask for confirmation rather than acting on the click")

    // Every button query below is scoped to the alert rather than to `app`:
    // the runner mirrors an alert's buttons into a simulated Touch Bar, so an
    // app-level "Cancel" matches twice and resolves to the Touch Bar copy,
    // which XCUITest refuses to click ("cannot be called with Touch Bar
    // elements"). AppKit decides whether a SwiftUI alert is a sheet on its
    // window or a free-standing dialog, so accept either.
    guard let confirmation = [app.sheets.firstMatch, app.dialogs.firstMatch].first(where: { $0.exists })
    else {
      // Dump the tree rather than just failing: which element the alert is, is
      // the one thing this test can't find out from a red CI run.
      XCTFail("The confirmation is neither a sheet nor a dialog:\n\(app.debugDescription)")
      return
    }
    XCTAssertTrue(
      confirmation.buttons["Reset and Restart"].exists,
      "The confirmation should say that Blurt restarts when the reset finishes")

    confirmation.buttons["Cancel"].click()

    XCTAssertTrue(
      confirmationTitle.waitForNonExistence(timeout: 5), "Cancel should dismiss the confirmation")
    XCTAssertEqual(
      "\(developerMode.value ?? "")", "1",
      "Cancelling the confirmation should leave the settings alone")
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

  // MARK: - Keys

  /// The trigger keys' keycodes (`TriggerKey`'s raw values), which suffix each
  /// pop-up's identifier in the Keys tab. Spelled out because this bundle
  /// doesn't link the engine.
  private let rightCommand = 54
  private let rightOption = 61
  private let fnKey = 63
  private let leftCommand = 55
  private let leftOption = 58
  private let leftControl = 59

  /// The Keys tab has an action and a mode pop-up per trigger key. On a reset
  /// launch right ⌘ dictates and, as the only dictating key, can't be turned
  /// off; left ⌥ reads aloud on a tap or hold; the rest are off, with no mode
  /// to pick.
  func testKeysTabListsEveryKey() {
    let keys = openKeys()

    for keyCode in [rightCommand, rightOption, fnKey, leftCommand, leftOption, leftControl] {
      XCTAssertTrue(
        keys.popUpButtons[UITestIdentifiers.keyStylePicker(keyCode)].exists,
        "The tab should list an action pop-up for keycode \(keyCode)")
      XCTAssertTrue(
        keys.popUpButtons[UITestIdentifiers.keyActivationPicker(keyCode)].exists,
        "The tab should list a mode pop-up for keycode \(keyCode)")
    }
    XCTAssertEqual(keys.popUpButtons[UITestIdentifiers.keyStylePicker(rightOption)].value as? String, "Off")
    XCTAssertFalse(keys.popUpButtons[UITestIdentifiers.keyActivationPicker(rightOption)].isEnabled)
    XCTAssertEqual(
      keys.popUpButtons[UITestIdentifiers.keyStylePicker(leftOption)].value as? String, KeyActionName.readAloud)
    XCTAssertEqual(
      keys.popUpButtons[UITestIdentifiers.keyActivationPicker(leftOption)].value as? String, "Tap or hold")

    let bound = keys.popUpButtons[UITestIdentifiers.keyStylePicker(rightCommand)]
    XCTAssertEqual(bound.value as? String, "Dictate")
    bound.click()
    XCTAssertTrue(bound.menuItems["Dictate"].waitForExistence(timeout: 5))
    XCTAssertFalse(bound.menuItems["Off"].exists, "The only dictating key can't be turned off")
    XCTAssertFalse(bound.menuItems[KeyActionName.readAloud].exists, "…nor set to read aloud")
    // Close the menu by re-choosing the current item, leaving the setting as it was.
    bound.menuItems["Dictate"].click()
  }

  /// A key's mode persists: the tab shows it again after another pane.
  func testKeyModePersists() {
    openKeys().popUpButtons[UITestIdentifiers.keyActivationPicker(leftOption)].click()
    app.menuItems["Hold"].click()

    let settings = openSettingsWindow()
    let reopened = selectSettingsTab(settings, named: UITestIdentifiers.keysSettingsTab)
    XCTAssertEqual(
      reopened.popUpButtons[UITestIdentifiers.keyActivationPicker(leftOption)].value as? String, "Hold",
      "The mode should survive leaving the tab")
  }

  /// The Read Aloud tab's voice picker starts on the service's default voice.
  func testVoicePickerDefaultsToJane() {
    let pane = selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.readAloudSettingsTab)
    let voice = pane.popUpButtons[UITestIdentifiers.readAloudVoicePicker]
    XCTAssertTrue(voice.waitForExistence(timeout: 5), "Voice picker not found")
    XCTAssertEqual(voice.value as? String, "Jane")
  }

  /// Opens Settings on the Keys tab and returns it.
  private func openKeys() -> XCUIElement {
    selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.keysSettingsTab)
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
