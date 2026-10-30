import XCTest

/// The Read Aloud tab and read-aloud's own sound: each setting persists, the
/// controls follow whether any key reads aloud, the privacy notes follow what
/// the keys do, and the voice and speed picked are the ones a read uses.
final class ReadAloudSettingsUITests: BlurtUITestCase {
  private func readAloudTab() -> XCUIElement {
    selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.readAloudSettingsTab)
  }

  /// Picks `item` from `popUp`'s menu.
  private func choose(_ item: String, in popUp: XCUIElement) {
    XCTAssertTrue(popUp.waitForExistence(timeout: 5), "Pop-up not found")
    popUp.click()
    popUp.menuItems[item].click()
  }

  // MARK: - U1: the read-aloud sound

  /// Read-aloud's sound starts on the Juno's Brass and is its own setting:
  /// changing it leaves dictation's alone, and it sticks.
  func testReadAloudSoundIsItsOwnSetting() {
    let general = openSettingsWindow()
    let read = general.popUpButtons[UITestIdentifiers.readAloudSoundPicker]
    let dictation = general.popUpButtons[UITestIdentifiers.soundPicker]
    XCTAssertTrue(read.waitForExistence(timeout: 5))
    XCTAssertEqual(read.value as? String, "Brass")
    XCTAssertEqual(dictation.value as? String, "Orchestra")

    choose("Clav 1", in: read)
    XCTAssertEqual(read.value as? String, "Clav 1")
    XCTAssertEqual(dictation.value as? String, "Orchestra", "Read-aloud's sound must not change dictation's")

    choose("Brass 1", in: dictation)
    XCTAssertEqual(read.value as? String, "Clav 1", "…nor dictation's change read-aloud's")

    let reopened = selectSettingsTab(
      selectSettingsTab(general, named: UITestIdentifiers.readAloudSettingsTab),
      named: UITestIdentifiers.generalSettingsTab)
    XCTAssertEqual(reopened.popUpButtons[UITestIdentifiers.readAloudSoundPicker].value as? String, "Clav 1")
  }

  // MARK: - U2: the Read Aloud tab

  /// Skipping technical text starts on, and a picked speed sticks.
  func testDefaultsAndSpeedPersist() {
    let tab = readAloudTab()
    let skip = tab.anyDescendant(identified: UITestIdentifiers.readAloudSkipsJargonToggle)
    XCTAssertTrue(skip.waitForExistence(timeout: 5))
    XCTAssertEqual(skip.value as? Int ?? Int(skip.value as? String ?? ""), 1, "Skip technical text should start on")

    choose("1.5×", in: tab.popUpButtons[UITestIdentifiers.readAloudSpeedPicker])
    let reopened = selectSettingsTab(
      selectSettingsTab(tab, named: UITestIdentifiers.generalSettingsTab),
      named: UITestIdentifiers.readAloudSettingsTab)
    XCTAssertEqual(reopened.popUpButtons[UITestIdentifiers.readAloudSpeedPicker].value as? String, "1.5×")
  }

  /// With no key reading aloud or asking, the controls are disabled and the tab
  /// says how to turn read-aloud on; a key that asks adds the gateway note.
  func testControlsAndNotesFollowTheKeys() {
    let harness = readyHarness()
    pick("left ⌥", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetOff].click()

    let tab = readAloudTab()
    let voice = tab.popUpButtons[UITestIdentifiers.readAloudVoicePicker]
    XCTAssertTrue(voice.waitForExistence(timeout: 5))
    XCTAssertFalse(voice.isEnabled, "With no read or ask key, the voice can't be picked")
    let assign = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "to enable playback", "to enable playback")
    XCTAssertTrue(tab.staticTexts.matching(assign).firstMatch.exists, "The tab should say how to turn it on")

    harness.click()
    pick("left ⌃", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetAsk].click()
    let tabAgain = readAloudTab()
    let gateway = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "spoken request", "spoken request")
    XCTAssertTrue(
      tabAgain.staticTexts.matching(gateway).firstMatch.waitForExistence(timeout: 5),
      "A key that asks should add the LLM Gateway note")
    XCTAssertTrue(tabAgain.popUpButtons[UITestIdentifiers.readAloudVoicePicker].isEnabled)
  }

  /// The voice and speed picked are the ones the next read speaks with.
  func testPickedVoiceAndSpeedReachARead() {
    let harness = readyHarness()
    let tab = readAloudTab()
    choose("Buford (British)", in: tab.popUpButtons[UITestIdentifiers.readAloudVoicePicker])
    choose("1.5×", in: tab.popUpButtons[UITestIdentifiers.readAloudSpeedPicker])

    harness.click()
    startRead(in: harness)
    XCTAssertEqual(spokenStyle(in: harness), "aai-buford @ 1.5")
  }
}
