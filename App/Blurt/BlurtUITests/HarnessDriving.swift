import XCTest

/// Driving the UI-test harness (`UITestHarnessView`): picking a trigger key,
/// setting the transcript, dictating, reading aloud, and reading the harness's
/// read-outs. Shared by the suites that exercise the keys and read-aloud.
extension BlurtUITestCase {

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
    guard element.exists else { return "" }
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
  func waitForText(_ element: XCUIElement, containing fragment: String, timeout: TimeInterval = 10, _ message: String) {
    let predicate = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)
    let result = XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
    XCTAssertEqual(result, .completed, message)
  }
}
