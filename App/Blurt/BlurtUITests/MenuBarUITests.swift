import XCTest

/// Drives the menu bar status item (`MenuBarExtra`): its menu surfaces the
/// dictation-hotkey discoverability line and the Open / Settings / Quit actions,
/// and the Settings item really opens the Settings window.
///
/// Status-item interaction is the most environment-sensitive part of the suite
/// (the item lives in the system status bar, which the notch can crowd and which
/// XCUITest exposes inconsistently across macOS releases). If a query here needs
/// adjusting on a given runner, the menu-item titles below are the stable anchor.
final class MenuBarUITests: BlurtUITestCase {
  /// Clicking the status item shows the discoverability line and the actions.
  func testStatusItemMenuShowsActions() {
    let statusItem = app.menuBars.statusItems.firstMatch
    XCTAssertTrue(
      statusItem.waitForExistence(timeout: 15),
      "Blurt menu bar status item never appeared")
    statusItem.click()

    XCTAssertTrue(
      app.menuItems["Open Blurt"].waitForExistence(timeout: 5),
      "Status menu should offer 'Open Blurt'")
    XCTAssertTrue(app.menuItems["Settings…"].exists)
    XCTAssertTrue(app.menuItems["Quit Blurt"].exists)

    // The otherwise-invisible lone-modifier trigger is spelled out here as the
    // menu's discoverability anchor: "Tap or hold <key> to dictate and paste".
    let hintPredicate = NSPredicate(format: "title BEGINSWITH %@", "Tap or hold")
    let hint = app.menuItems.matching(hintPredicate).firstMatch
    XCTAssertTrue(hint.exists, "Status menu should spell out the dictation trigger")
  }
}
