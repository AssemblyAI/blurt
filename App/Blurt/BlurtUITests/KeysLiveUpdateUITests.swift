import XCTest

/// The ready screen and the menu bar follow the keys as they change, without a
/// relaunch: a key given an action gains a row, and moving dictation to
/// another key renames the dictation row and the menu bar's reminder.
final class KeysLiveUpdateUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] { [UITestIdentifiers.readyLaunchArgument] }

  private func row(_ label: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
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
    XCTAssertTrue(row("\(KeyActionName.readAloud): Right Command.").exists)

    let statusItem = app.menuBars.statusItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 15))
    statusItem.click()
    let hint = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "right ⌥ to dictate")).firstMatch
    XCTAssertTrue(hint.waitForExistence(timeout: 5), "The menu bar's reminder should name right ⌥")
    app.typeKey(.escape, modifierFlags: [])
  }
}
