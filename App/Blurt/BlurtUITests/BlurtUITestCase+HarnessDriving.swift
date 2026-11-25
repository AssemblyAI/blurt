import XCTest

/// Driving the UI-test harness (`UITestHarnessView`): picking a trigger key,
/// setting the transcript, dictating, reading aloud, and reading the harness's
/// read-outs. Shared by the suites that exercise the keys and read-aloud.
extension BlurtUITestCase {
  /// The open item's toolbar View menu.
  var viewPicker: XCUIElement {
    app.menuButtons[UITestIdentifiers.facetPicker].firstMatch
  }

  /// The harness, with an API key set so presses clear the missing-key gate.
  func readyHarness() -> XCUIElement {
    let harness = harnessWindow()
    harness.buttons[UITestIdentifiers.setKeyButton].click()
    return harness
  }

  /// Points the harness's press/release buttons at `key`.
  func pick(_ key: String, in harness: XCUIElement) {
    let picker = harness.popUpButtons[UITestIdentifiers.harnessKeyPicker]
    XCTAssertTrue(picker.waitForExistence(timeout: 5), "The harness key picker not found")
    picker.click()
    picker.menuItems[key].click()
  }

  /// Sets `key` to the job a harness button names (`harnessSetAsk`,
  /// `harnessSetCommand`, …), and points the press/release buttons at it.
  func bind(_ key: String, with setButton: String, in harness: XCUIElement) {
    pick(key, in: harness)
    harness.buttons[setButton].click()
  }

  /// Holds the picked key through a request: press, recording, release.
  func hold(in harness: XCUIElement) {
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusRecording, "A held key should record")
    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
  }

  func setTranscript(_ text: String, in harness: XCUIElement) {
    let field = harness.textFields[UITestIdentifiers.transcriptField]
    field.click()
    field.typeKey("a", modifierFlags: .command)
    // Typing nothing wouldn't replace the selection, so clear it first.
    field.typeKey(.delete, modifierFlags: [])
    field.typeText(text)
  }

  /// A hold of the picked key: records, then pastes `transcript`.
  func dictate(in harness: XCUIElement, expecting transcript: String, _ message: String) {
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusRecording, "\(message): no recording")
    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
    waitForLabel(pastedLabel(in: harness), equals: transcript, timeout: 15, "\(message): nothing pasted")
    waitForLabel(statusLabel(in: harness), equals: UITestIdentifiers.statusIdle)
  }

  /// A tap of left ⌥ (reading aloud by default), until the read is playing.
  func startRead(in harness: XCUIElement) {
    pick("left ⌥", in: harness)
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    harness.buttons[UITestIdentifiers.hotkeyTapReleaseButton].click()
    waitForLabel(spoken(in: harness), equals: UITestIdentifiers.cannedSelection, "The selection should be read")
    waitForLabel(reading(in: harness), equals: "yes", "The read should be playing")
  }

  func addStyle(named name: String, instructions: String, in settings: XCUIElement) {
    let styles = selectSettingsTab(settings, named: UITestIdentifiers.stylesSettingsTab)
    styles.buttons[UITestIdentifiers.styleProfileAdd].click()
    let sheet = styles.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The Add Style sheet should open")
    fill(name, into: UITestIdentifiers.styleProfileName, in: sheet)
    fill(instructions, into: UITestIdentifiers.styleProfileInstructions, in: sheet)
    sheet.buttons[UITestIdentifiers.styleProfileSave].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Saving should dismiss the style sheet")
  }

  func fill(_ text: String, into identifier: String, in sheet: XCUIElement) {
    let field = sheet.anyDescendant(identified: identifier)
    XCTAssertTrue(field.waitForExistence(timeout: 5), "Field \(identifier) not found")
    field.click()
    field.typeText(text)
  }

  func statusLabel(in harness: XCUIElement) -> XCUIElement {
    harness.staticTexts[UITestIdentifiers.statusLabel]
  }

  func pastedLabel(in harness: XCUIElement) -> XCUIElement {
    harness.staticTexts[UITestIdentifiers.pastedLabel]
  }

  func reading(in harness: XCUIElement) -> XCUIElement {
    harness.staticTexts[UITestIdentifiers.readingLabel]
  }

  func spoken(in harness: XCUIElement) -> XCUIElement {
    harness.staticTexts[UITestIdentifiers.spokenLabel]
  }

  /// A read-out's string. An empty SwiftUI `Text` isn't in the accessibility
  /// tree at all, so a read-out that isn't there reads as "".
  func text(of element: XCUIElement) -> String {
    guard element.exists else {
      return ""
    }
    return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
  }

  func status(in harness: XCUIElement) -> String { text(of: statusLabel(in: harness)) }
  func pasted(in harness: XCUIElement) -> String { text(of: pastedLabel(in: harness)) }
  func sentStyle(in harness: XCUIElement) -> String {
    text(of: harness.staticTexts[UITestIdentifiers.sentStyleLabel])
  }

  func spokenStyle(in harness: XCUIElement) -> String {
    text(of: harness.staticTexts[UITestIdentifiers.spokenStyleLabel])
  }

  /// Waits for `element`'s string to contain `fragment`.
  func waitForText(_ element: XCUIElement, containing fragment: String, _ message: String, timeout: TimeInterval = 10) {
    let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)
    let result = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout
    )
    XCTAssertEqual(result, .completed, message)
  }

  // MARK: - The Library and an open item

  /// A Library row by its title. The row is one combined element whose text
  /// ("<title>, <details>") XCUITest may report as its label or its value.
  func row(titled title: String) -> XCUIElement {
    let titled = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", title, title)
    return app.windows[UITestIdentifiers.mainWindowTitle].descendants(matching: .any).matching(titled).firstMatch
  }

  /// Static text in the main window containing `text`. A typed query:
  /// matching `.any` element across the window is slow enough on this
  /// hierarchy for XCUITest to time out.
  func text(containing text: String) -> XCUIElement {
    app.windows[UITestIdentifiers.mainWindowTitle].staticTexts
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }

  /// Anything in the app showing `text` — the open item's transcript. A
  /// speaker turn is one combined element — a group, not static text — so any
  /// type is matched.
  func windowText(containing text: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
  }

  /// Shows the view titled `title`, from the toolbar's View menu.
  func showView(_ title: String) {
    XCTAssertTrue(viewPicker.waitForExistence(timeout: 5), "The open item's View menu not found")
    viewPicker.click()
    viewPicker.menuItems[title].click()
  }

  // MARK: - A live recording

  /// Starts a recording with the ready screen's Record button — offline, on
  /// `TranscriptsModel.uiTest(store:)`'s capture and live-session doubles —
  /// and waits for the live page.
  func startLiveRecording(in main: XCUIElement) {
    let record = main.buttons[UITestIdentifiers.transcribeRecordButton]
    XCTAssertTrue(record.waitForExistence(timeout: 10), "The Record button not found")
    record.click()
    XCTAssertTrue(
      main.buttons[UITestIdentifiers.liveRecordingStop].waitForExistence(timeout: 10),
      "Record should open the live page"
    )
  }

  /// Releases the scripted live session's next turn, from the harness, then
  /// brings the main window back to the front. The click raises the harness,
  /// pinned top-leading, and how far it reaches over the centred main window
  /// depends on the screen: Discard…, at the live page's leading edge, missed
  /// its click after a turn while Pause and Stop, at the trailing edge, never
  /// did. A click on the main window's centre — the live transcript, inert —
  /// raises it from anywhere the harness can't reach.
  func releaseLiveTurn(in harness: XCUIElement) {
    harness.buttons[UITestIdentifiers.harnessLiveNextTurn].click()
    app.windows[UITestIdentifiers.mainWindowTitle].click()
  }
}
