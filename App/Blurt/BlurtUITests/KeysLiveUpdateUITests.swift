import XCTest

/// The ready screen and the menu bar follow the keys as they change, without a
/// relaunch: a key given a new action gains a row, and moving dictation to
/// another key renames the dictation row and the menu bar's reminder.
final class KeysLiveUpdateUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] { [UITestIdentifiers.readyLaunchArgument] }

  /// A Keys row whose label starts with `label` — and names `key`, for a row
  /// that lists several keys.
  private func row(_ label: String, containing key: String = "") -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", label, key)
    ).firstMatch
  }

  func testReadyScreenAndMenuBarFollowTheKeys() {
    // Both windows looked up directly, as ReadyViewUITests does: the shared
    // window helpers each close every window but the one they return.
    let harness = app.windows[UITestIdentifiers.harnessWindowTitle]
    XCTAssertTrue(harness.waitForExistence(timeout: 10), "Harness window not presented")
    XCTAssertTrue(
      app.windows[UITestIdentifiers.mainWindowTitle].waitForExistence(timeout: 10), "Ready window not presented")
    harness.buttons[UITestIdentifiers.setKeyButton].click()

    pick("left ⌃", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetAsk].click()
    XCTAssertTrue(
      row("\(KeyActionName.ask): Left Control.").waitForExistence(timeout: 5),
      "The ready screen should gain a row for the key that asks")

    pick("right ⌥", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetDictate].click()
    pick("right ⌘", in: harness)
    harness.buttons[UITestIdentifiers.harnessSetReadAloud].click()
    XCTAssertTrue(
      row("Dictate: Right Option.").waitForExistence(timeout: 5),
      "Dictation moved to right ⌥, so the dictation row should name it")
    // Right ⌘ joins left ⌥ on the one read-aloud row, its keycaps side by side.
    XCTAssertTrue(
      row("\(KeyActionName.readAloud):", containing: "Right Command").exists,
      "The read-aloud row should list right ⌘")

    let statusItem = app.menuBars.statusItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 15))
    statusItem.click()
    let hint = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "right ⌥ to dictate")).firstMatch
    XCTAssertTrue(hint.waitForExistence(timeout: 5), "The menu bar's reminder should name right ⌥")
    app.typeKey(.escape, modifierFlags: [])
  }
}
