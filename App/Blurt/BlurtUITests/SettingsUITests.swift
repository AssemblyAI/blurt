import XCTest

/// Drives the Settings window: the microphone and sound-cue pickers, the Styles
/// pane's enhanced-transcripts switch, and the Advanced pane. (The API-key sheet
/// is in `APIKeySheetUITests`, the Keys tab in `KeysAndReadAloudUITests`, the
/// Read Aloud tab in `ReadAloudSettingsUITests`, the Vocabulary pane in
/// `TextShortcutsUITests`.)
final class SettingsUITests: BlurtUITestCase {
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
      "The picker should start on the system default (got: \(value))"
    )
  }

  /// The sound-cue picker changes the persisted selection. Selecting "None"
  /// works regardless of the runner's persisted starting value. The sounds
  /// are their own pane, so switch to it first.
  func testSoundPickerChangesSelection() {
    let settings = selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.soundsSettingsTab)

    let picker = settings.popUpButtons[UITestIdentifiers.keySoundPicker(54)]
    XCTAssertTrue(picker.waitForExistence(timeout: 10), "Sound picker not found")
    picker.click()
    app.menuItems["None"].click()

    XCTAssertEqual(picker.value as? String, "None", "Choosing None should stick as the selection")
  }

  /// The Escape cancel is an experimental switch: shown in the Advanced pane with
  /// developer mode off, off by default, and on with a click.
  func testEscapeCancelIsAnExperimentalSwitchThatDefaultsOff() {
    let advanced = selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.advancedSettingsTab)
    let developer = advanced.anyDescendant(identified: UITestIdentifiers.developerToggle)
    XCTAssertTrue(developer.waitForExistence(timeout: 10), "Developer mode toggle not found")
    XCTAssertEqual("\(developer.value ?? "")", "0", "Developer mode should start switched off")

    let toggle = advanced.anyDescendant(identified: UITestIdentifiers.escapeCancelToggle)
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Cancel-with-Escape toggle not found")
    XCTAssertEqual("\(toggle.value ?? "")", "0", "Cancel with Escape should default OFF")
    toggle.click()
    XCTAssertEqual("\(toggle.value ?? "")", "1", "Clicking should turn Cancel with Escape on")
  }

  /// The media pause is an experimental switch: shown in the Advanced pane with
  /// developer mode off, off by default, and on with a click.
  func testMediaPauseIsAnExperimentalSwitchThatDefaultsOff() {
    let advanced = selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.advancedSettingsTab)
    let toggle = advanced.anyDescendant(identified: UITestIdentifiers.pauseMediaToggle)
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Pause-music toggle not found")
    XCTAssertEqual("\(toggle.value ?? "")", "0", "Pausing music should default OFF")
    toggle.click()
    let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: toggle)
    XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 10), .completed, "Clicking should turn pausing music on")
  }

  /// Developer mode starts off (the UI-test launch resets persisted settings)
  /// and a click switches it on, growing the row that shows the logs — which
  /// goes again when it's switched off. Matched by identifier rather than
  /// element type so the test doesn't care whether AppKit exposes the SwiftUI
  /// switch as a switch or a checkbox. The toggle lives on the Advanced pane, so
  /// switch to that tab first. (Show in Finder isn't clicked: it opens Finder.)
  func testDeveloperModeTogglesOnAndShowsTheLogsRow() {
    let settings = openSettingsWindow()
    let advanced = selectSettingsTab(settings, named: UITestIdentifiers.advancedSettingsTab)

    let toggle = advanced.anyDescendant(identified: UITestIdentifiers.developerToggle)
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Developer mode toggle not found")
    XCTAssertEqual("\(toggle.value ?? "")", "0", "Developer mode should start switched off")
    let showLogs = advanced.anyDescendant(identified: UITestIdentifiers.developerShowLogs)
    XCTAssertFalse(showLogs.exists, "With developer mode off there are no logs to show")

    toggle.click()

    XCTAssertEqual("\(toggle.value ?? "")", "1", "Clicking should switch developer mode on")
    XCTAssertTrue(showLogs.waitForExistence(timeout: 5), "Developer mode should offer to show its logs")

    toggle.click()
    XCTAssertTrue(showLogs.waitForNonExistence(timeout: 5), "Switching off should remove the logs row")
  }

  /// Enhanced transcripts start on, with the dictation mode on Smart. The mode
  /// and the styles only shape the enhanced rewrite, so switching it off
  /// disables both, and switching it back on re-enables them.
  func testEnhancedTranscriptsSwitchGatesModeAndStyles() {
    let styles = selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.stylesSettingsTab)
    let enhanced = styles.anyDescendant(identified: UITestIdentifiers.enhancedTranscriptsToggle)
    XCTAssertTrue(enhanced.waitForExistence(timeout: 10), "Enhanced transcripts toggle not found")
    XCTAssertEqual("\(enhanced.value ?? "")", "1", "Enhanced transcripts should default ON")
    let mode = styles.popUpButtons[UITestIdentifiers.rewriteModePicker]
    let add = styles.buttons[UITestIdentifiers.styleProfileAdd]
    XCTAssertTrue(mode.waitForExistence(timeout: 5), "Dictation mode picker not found")
    XCTAssertEqual(mode.value as? String, "Smart", "Dictation mode should default to Smart")
    XCTAssertTrue(mode.isEnabled)
    XCTAssertTrue(add.isEnabled)

    enhanced.click()
    let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: mode)
    XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 5), .completed, "Switching off should disable the mode")
    XCTAssertFalse(add.isEnabled, "Switching off should disable adding a style")

    enhanced.click()
    let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: mode)
    XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 5), .completed, "Switching on should re-enable the mode")
    XCTAssertTrue(add.isEnabled, "Switching on should re-enable adding a style")
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
  /// Everything happens on the Advanced pane, against an Experimental switch
  /// — one of the settings `PersistedSettings.resetAll` clears — so "nothing was
  /// reset" is observable without switching tabs or opening the API-key sheet.
  /// Not developer mode, whose rows and footer grow the pane: the panes don't
  /// scroll, so a taller one pushed the reset button off a small CI screen.
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
    let setting = advanced.anyDescendant(identified: UITestIdentifiers.pauseMediaToggle)
    XCTAssertTrue(setting.waitForExistence(timeout: 10), "Pause music toggle not found")
    setting.click()
    let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: setting)
    XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 10), .completed, "Clicking should switch Pause music on")

    let reset = advanced.anyDescendant(identified: UITestIdentifiers.installReset)
    XCTAssertTrue(reset.waitForExistence(timeout: 10), "Reset button not found")
    reset.click()

    // Queried off `app`, not off the settings window: a SwiftUI `.alert` isn't
    // necessarily a sheet of the window it was declared in, so the confirmation
    // is identified by the words on it wherever AppKit chose to put it.
    let confirmationTitle = app.staticTexts["Reset Blurt?"]
    XCTAssertTrue(
      confirmationTitle.waitForExistence(timeout: 10),
      "Reset should ask for confirmation rather than acting on the click"
    )

    // Every button query below is scoped to the alert rather than to `app`:
    // the runner mirrors an alert's buttons into a simulated Touch Bar, so an
    // app-level "Cancel" matches twice and resolves to the Touch Bar copy,
    // which XCUITest refuses to click ("cannot be called with Touch Bar
    // elements"). AppKit decides whether a SwiftUI alert is a sheet on its
    // window or a free-standing dialog, so accept either.
    guard let confirmation = [app.sheets.firstMatch, app.dialogs.firstMatch].first(where: \.exists)
    else {
      // Dump the tree rather than just failing: which element the alert is, is
      // the one thing this test can't find out from a red CI run.
      XCTFail("The confirmation is neither a sheet nor a dialog:\n\(app.debugDescription)")
      return
    }
    XCTAssertTrue(
      confirmation.buttons["Reset and Restart"].exists,
      "The confirmation should say that Blurt restarts when the reset finishes"
    )

    confirmation.buttons["Cancel"].click()

    XCTAssertTrue(
      confirmationTitle.waitForNonExistence(timeout: 5), "Cancel should dismiss the confirmation"
    )
    XCTAssertEqual(
      "\(setting.value ?? "")",
      "1",
      "Cancelling the confirmation should leave the settings alone"
    )
  }
}
