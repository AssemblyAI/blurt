import XCTest

/// Drives the Settings window's Text Shortcuts pane and its editor sheet: add,
/// edit, delete, and the duplicate-phrase refusal. Offline — the pane only reads
/// and writes `UserDefaults`, which the UI-test launch resets, so every case
/// starts from an empty list.
final class TextShortcutsUITests: BlurtUITestCase {
  /// The whole lifecycle of one shortcut, asserted through the list the sheet
  /// writes back to — so the store write, the `@AppStorage` refresh and the
  /// row identifiers are all on the path.
  func testAddEditAndDeleteShortcut() {
    let pane = openTextShortcutsPane()

    addShortcut(in: pane, trigger: "work email", expansion: "me@example.com")
    XCTAssertTrue(
      row(in: pane, containing: "me@example.com").waitForExistence(timeout: 5),
      "A saved shortcut should appear in the list")

    let sheet = openSheet(in: pane, via: UITestIdentifiers.textShortcutEdit(0))
    let expansion = sheet.anyDescendant(identified: UITestIdentifiers.textShortcutExpansion)
    expansion.click()
    expansion.typeKey("a", modifierFlags: .command)
    expansion.typeText("you@example.com")
    sheet.buttons[UITestIdentifiers.textShortcutSave].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Save should dismiss the sheet")
    XCTAssertTrue(
      row(in: pane, containing: "you@example.com").waitForExistence(timeout: 5),
      "An edit should replace the row's text")
    XCTAssertFalse(
      row(in: pane, containing: "me@example.com").exists,
      "An edit should not leave the old text behind")

    let deleting = openSheet(in: pane, via: UITestIdentifiers.textShortcutEdit(0))
    deleting.buttons[UITestIdentifiers.textShortcutDelete].click()
    XCTAssertTrue(deleting.waitForNonExistence(timeout: 5), "Delete should dismiss the sheet")
    XCTAssertTrue(
      pane.buttons[UITestIdentifiers.textShortcutEdit(0)].waitForNonExistence(timeout: 5),
      "Delete should remove the row")
  }

  /// A phrase the matcher can't tell from an existing one — differing only in
  /// case and separators — would be dropped by the store on save, so the sheet
  /// refuses it up front: Save stays disabled rather than silently losing it.
  func testDuplicatePhraseLeavesSaveDisabled() {
    let pane = openTextShortcutsPane()
    addShortcut(in: pane, trigger: "work email", expansion: "me@example.com")

    let sheet = openSheet(in: pane, via: UITestIdentifiers.textShortcutAdd)
    type("Work-Email", into: UITestIdentifiers.textShortcutTrigger, in: sheet)
    type("other@example.com", into: UITestIdentifiers.textShortcutExpansion, in: sheet)

    let save = sheet.buttons[UITestIdentifiers.textShortcutSave]
    XCTAssertFalse(save.isEnabled, "Save should stay disabled for a duplicate phrase")

    sheet.buttons[UITestIdentifiers.textShortcutCancel].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Cancel should dismiss the sheet")
    XCTAssertFalse(
      pane.buttons[UITestIdentifiers.textShortcutEdit(1)].exists,
      "A refused duplicate should not add a row")
  }

  // MARK: - Helpers

  private func openTextShortcutsPane() -> XCUIElement {
    let settings = openSettingsWindow()
    return selectSettingsTab(settings, named: UITestIdentifiers.textShortcutsTab)
  }

  private func openSheet(in pane: XCUIElement, via identifier: String) -> XCUIElement {
    let button = pane.buttons[identifier]
    XCTAssertTrue(button.waitForExistence(timeout: 10), "Button \(identifier) not found")
    button.click()
    let sheet = pane.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5), "The shortcut sheet should open")
    return sheet
  }

  private func type(_ text: String, into identifier: String, in sheet: XCUIElement) {
    let field = sheet.anyDescendant(identified: identifier)
    XCTAssertTrue(field.waitForExistence(timeout: 5), "Field \(identifier) not found")
    field.click()
    field.typeText(text)
  }

  /// Adds one shortcut through the sheet, waiting on the sheet's disappearance
  /// for the reason on `SettingsUITests.connectValidKey`.
  private func addShortcut(in pane: XCUIElement, trigger: String, expansion: String) {
    let sheet = openSheet(in: pane, via: UITestIdentifiers.textShortcutAdd)
    type(trigger, into: UITestIdentifiers.textShortcutTrigger, in: sheet)
    type(expansion, into: UITestIdentifiers.textShortcutExpansion, in: sheet)
    sheet.buttons[UITestIdentifiers.textShortcutSave].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Save should dismiss the sheet")
  }

  /// A row's read-out, matched on its label: the row combines trigger and
  /// replacement into one accessibility element, so neither is its own text.
  private func row(in pane: XCUIElement, containing text: String) -> XCUIElement {
    pane.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }
}
