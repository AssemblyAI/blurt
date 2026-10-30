import XCTest

/// Every trigger key and what it can do, end to end through the real key tap
/// (the harness drives its gate and callbacks — see `UITestHarnessView`): each
/// key dictating, a key turned off, the read-aloud and ask keys, the dictation
/// key interrupting a read, a key's own dictation style, and text shortcuts
/// expanding in what's pasted. Read-aloud runs offline: the selection is
/// `UITestIdentifiers.cannedSelection`, and the stub speaker reports what it
/// was asked to read on the harness's Spoken read-out.
final class KeysAndReadAloudUITests: BlurtUITestCase {
  /// Each `TriggerKey`'s label, as the harness's key picker lists it. Spelled
  /// out because this bundle doesn't link the engine.
  private let allKeys = ["right ⌘", "right ⌥", "fn", "left ⌘", "left ⌥", "left ⌃"]

  // MARK: - Every key

  /// Each key, set to dictate, records on a press and pastes on its release.
  /// Each but the bound key, set to off, then starts nothing.
  func testEveryKeyDictatesAndCanBeTurnedOff() {
    let harness = readyHarness()
    for key in allKeys {
      pick(key, in: harness)
      harness.buttons[UITestIdentifiers.harnessSetDictate].click()
      let transcript = "Dictated with \(key)."
      setTranscript(transcript, in: harness)
      dictate(in: harness, expecting: transcript, "\(key) should dictate")
    }
    for key in allKeys.dropFirst() {
      pick(key, in: harness)
      harness.buttons[UITestIdentifiers.harnessSetOff].click()
      harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
      sleep(1)
      XCTAssertEqual(status(in: harness), UITestIdentifiers.statusIdle, "\(key), turned off, should start nothing")
      harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
    }
  }

  // MARK: - Read aloud and ask

  /// Left ⌥ reads aloud by default: a tap over a selection reads it, and
  /// nothing is recorded or pasted. Its next tap stops the read.
  func testReadAloudKeyReadsTheSelection() {
    let harness = readyHarness()
    startRead(in: harness)
    XCTAssertEqual(status(in: harness), UITestIdentifiers.statusIdle, "A read should not record")
    XCTAssertEqual(pasted(in: harness), "", "A read should paste nothing")

    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    harness.buttons[UITestIdentifiers.hotkeyTapReleaseButton].click()
    waitForLabel(reading(in: harness), equals: "no", "The read key's next tap should stop the read")
  }

  /// Pressing the dictation key during a read stops the read and dictates.
  func testDictationKeyInterruptsARead() {
    let harness = readyHarness()
    startRead(in: harness)
    pick("right ⌘", in: harness)
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    waitForLabel(reading(in: harness), equals: "no", "The dictation key should stop the read")
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusRecording, "…and start dictating")
    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
    waitForLabel(
      pastedLabel(in: harness), equals: UITestIdentifiers.defaultCannedTranscript, timeout: 15,
      "The dictation should paste")
  }

  /// A key set to ask, held over a selection, records the request and reads
  /// the answer aloud; the request itself is never pasted.
  func testAskKeyAnswersAboutTheSelection() {
    let harness = readyHarness()
    pick("left ⌃", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetAsk].click()
    setTranscript("Summarize this.", in: harness)
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusRecording, "A held ask should record")
    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
    waitForLabel(
      spoken(in: harness), equals: "Answer to: Summarize this.", timeout: 15, "The answer should be read aloud")
    XCTAssertEqual(pasted(in: harness), "", "The request should not be pasted")
  }

  // MARK: - Styles

  /// A style made in Settings shows up in the Keys tab's menu. The bound key
  /// dictates with the main window's style; a key set to "No custom style"
  /// sends none.
  func testEachKeyDictatesWithItsOwnStyle() {
    let harness = readyHarness()
    let settings = openSettingsWindow()
    addStyle(named: "Casual", instructions: "keep it breezy", in: settings)

    // The window's title follows its tab, so find it afresh before switching.
    let keys = selectSettingsTab(openSettingsWindow(), named: UITestIdentifiers.keysSettingsTab)
    let option = keys.popUpButtons[UITestIdentifiers.keyStylePicker(61)]
    XCTAssertTrue(option.waitForExistence(timeout: 5), "Right ⌥'s action pop-up not found")
    option.click()
    XCTAssertTrue(option.menuItems["Dictate: Casual"].waitForExistence(timeout: 5), "The new style should be offered")
    option.menuItems["Dictate: No custom style"].click()

    harness.click()
    pick("right ⌘", in: harness)
    dictate(in: harness, expecting: UITestIdentifiers.defaultCannedTranscript, "The bound key should dictate")
    XCTAssertTrue(
      sentStyle(in: harness).contains("keep it breezy"),
      "The bound key should send the main window's style (got: \(sentStyle(in: harness)))")

    pick("right ⌥", in: harness)
    setTranscript("Plain words.", in: harness)
    dictate(in: harness, expecting: "Plain words.", "Right ⌥ should dictate")
    XCTAssertEqual(sentStyle(in: harness), "—", "A key set to No custom style should send none")
  }

  // MARK: - Text shortcuts

  /// A text shortcut added in Settings expands in what a dictation pastes.
  func testTextShortcutExpandsInADictation() {
    let harness = readyHarness()
    let settings = openSettingsWindow()
    let vocabulary = selectSettingsTab(settings, named: UITestIdentifiers.vocabularySettingsTab)
    vocabulary.anyDescendant(identified: UITestIdentifiers.textShortcutAdd).click()
    let sheet = vocabulary.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The shortcut sheet should open")
    fill("my email", into: UITestIdentifiers.textShortcutTrigger, in: sheet)
    fill("alex@example.com", into: UITestIdentifiers.textShortcutExpansion, in: sheet)
    sheet.buttons[UITestIdentifiers.textShortcutSave].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Save should dismiss the sheet")

    harness.click()
    setTranscript("Send it to my email.", in: harness)
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusRecording)
    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
    waitForText(
      pastedLabel(in: harness), containing: "alex@example.com", timeout: 15,
      "The pasted text should carry the expansion (got: \(pasted(in: harness)))")
  }
}
