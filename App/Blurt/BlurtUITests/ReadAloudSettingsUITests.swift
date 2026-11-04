import XCTest

/// The Read Aloud tab and read-aloud's own sound: each setting persists, the
/// controls follow whether any key reads aloud, and the voice and speed picked
/// are the ones a read uses.
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

  /// The read-aloud key's sound starts on the Juno's Brass and is its own
  /// setting: changing it leaves the dictating key's alone, and it sticks.
  func testReadAloudSoundIsItsOwnSetting() {
    let sounds = selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.soundsSettingsTab)
    // Left ⌥ (58) reads aloud and right ⌘ (54) dictates on an untouched install.
    let read = sounds.popUpButtons[UITestIdentifiers.keySoundPicker(58)]
    let dictation = sounds.popUpButtons[UITestIdentifiers.keySoundPicker(54)]
    XCTAssertTrue(read.waitForExistence(timeout: 5))
    XCTAssertEqual(read.value as? String, "Brass")
    XCTAssertEqual(dictation.value as? String, "Orchestra")

    choose("Clav 1", in: read)
    XCTAssertEqual(read.value as? String, "Clav 1")
    XCTAssertEqual(dictation.value as? String, "Orchestra", "Read-aloud's sound must not change dictation's")

    choose("Brass 1", in: dictation)
    XCTAssertEqual(read.value as? String, "Clav 1", "…nor dictation's change read-aloud's")

    let reopened = selectSettingsTab(
      selectSettingsTab(sounds, named: UITestIdentifiers.readAloudSettingsTab),
      named: UITestIdentifiers.soundsSettingsTab)
    XCTAssertEqual(
      reopened.popUpButtons[UITestIdentifiers.keySoundPicker(58)].value as? String,
      "Clav 1")
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

  /// With no key reading aloud or asking, the controls are disabled; a key
  /// that asks enables them again.
  func testControlsFollowTheKeys() {
    let harness = readyHarness()
    bind("left ⌥", with: UITestIdentifiers.harnessSetOff, in: harness)

    let tab = readAloudTab()
    let voice = tab.popUpButtons[UITestIdentifiers.readAloudVoicePicker]
    XCTAssertTrue(voice.waitForExistence(timeout: 5))
    XCTAssertFalse(voice.isEnabled, "With no read or ask key, the voice can't be picked")

    harness.click()
    bind("left ⌃", with: UITestIdentifiers.harnessSetAsk, in: harness)
    let voiceAgain = readAloudTab().popUpButtons[UITestIdentifiers.readAloudVoicePicker]
    XCTAssertTrue(voiceAgain.waitForExistence(timeout: 5))
    XCTAssertTrue(voiceAgain.isEnabled, "A key that asks should enable the voice")
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
