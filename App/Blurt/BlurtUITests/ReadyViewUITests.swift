import AppKit
import XCTest

/// The "you're all set" ready screen (`ReadyView`) shown in the main window once
/// setup is complete. It's unreachable under the plain `-BlurtUITest` flag — the
/// test host can't grant the real TCC permissions readiness requires — so these
/// tests opt into `-BlurtUITestReady`, which forces the fully-configured state
/// (saved key + all permissions granted) so the main window renders `ReadyView`
/// instead of the setup wizard. The rest of the suite keeps exercising the
/// wizard under the plain flag.
final class ReadyViewUITests: BlurtUITestCase {
  override var extraLaunchArguments: [String] { [UITestIdentifiers.readyLaunchArgument] }

  func testReadyScreenShowsShortcutRecentAndSettings() {
    mainWindow()

    // The shortcut readout: "Tap or hold <key> to blurt".
    XCTAssertTrue(
      app.staticTexts["Tap or hold"].waitForExistence(timeout: 10),
      "Ready screen should state the dictation shortcut")
    XCTAssertTrue(app.staticTexts["to blurt"].exists)

    // The Recent section, empty on a fresh launch, shows its header and the
    // placeholder that fills the reserved list area.
    XCTAssertTrue(app.staticTexts["Recent"].exists, "Ready screen should have a Recent section")
    XCTAssertTrue(
      app.staticTexts["Your recent blurts will appear here"].exists,
      "An empty Recent list should show its placeholder")

    // The link back to Settings — the only actionable control on the screen.
    XCTAssertTrue(app.buttons["Settings"].exists, "Ready screen should offer a Settings link")
  }

  func testSettingsLinkOpensSettingsWindow() {
    mainWindow()

    let settingsButton = app.buttons["Settings"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 10), "Settings link not found")
    settingsButton.click()

    XCTAssertTrue(
      app.windows[UITestIdentifiers.settingsWindowTitle].waitForExistence(timeout: 10),
      "Clicking the ready screen's Settings link should open the Settings window")
  }

  func testCompletedDictationPopulatesRecentList() {
    let (harness, main) = readyScreenWindows()

    // The Recent list starts empty.
    XCTAssertTrue(
      main.staticTexts["Your recent blurts will appear here"].waitForExistence(timeout: 10),
      "Recent list should start empty")

    driveDictation(via: harness)

    // The completed dictation appears as a Recent row on the ready screen.
    let row = recentRow(in: main)
    XCTAssertTrue(
      row.waitForExistence(timeout: 10),
      "A completed dictation should appear in the ready screen's Recent list")
    XCTAssertFalse(
      main.staticTexts["Your recent blurts will appear here"].exists,
      "The empty-list placeholder should be gone once a dictation is recorded")
  }

  func testRecentRowCopyShowsConfirmation() {
    // Record a dictation, then copy it from the Recent row's context menu — the
    // row's copy affordance (`copyTranscript`: pasteboard write + a transient
    // "Copied" confirmation) that only `ReadyView` exercises.
    let (harness, main) = readyScreenWindows()

    driveDictation(via: harness)

    let row = recentRow(in: main)
    XCTAssertTrue(row.waitForExistence(timeout: 10), "Recent row not found")

    // Seed the pasteboard with a sentinel so the assertion can't pass on stale
    // contents — the copy must actually replace it.
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("sentinel-before-copy", forType: .string)

    // Right-click the row to reveal its "Copy" contextual menu item and invoke
    // it. Scope to the popup menu (`app.menus`) so it doesn't collide with the
    // always-present Edit-menu "Copy" in the main menu bar.
    row.rightClick()
    let copyItem = app.menus.menuItems["Copy"].firstMatch
    XCTAssertTrue(copyItem.waitForExistence(timeout: 5), "Recent row should offer a Copy action")
    copyItem.click()

    // The row writes the transcript to the system pasteboard (its "Copied" badge
    // is accessibility-hidden, so verify the real effect the copy has). Poll,
    // since the cross-process write lands a beat after the click.
    var copied: String?
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      copied = pasteboard.string(forType: .string)
      if copied == UITestIdentifiers.defaultCannedTranscript { break }
      usleep(100_000)
    }
    XCTAssertEqual(
      copied, UITestIdentifiers.defaultCannedTranscript,
      "Copying a recent transcript should put it on the pasteboard")
  }

  // MARK: - Shared choreography

  /// The two windows a ready-state launch presents. The harness sits in the
  /// top-leading corner (see `BlurtApp`) so it never overlaps the centered ready
  /// window: a test can drive a full dictation on the harness, then read the
  /// result on the still-open ready screen — no closing/reopening.
  private func readyScreenWindows() -> (harness: XCUIElement, main: XCUIElement) {
    let harness = app.windows[UITestIdentifiers.harnessWindowTitle]
    XCTAssertTrue(harness.waitForExistence(timeout: 10), "Harness window not presented")
    let main = app.windows[UITestIdentifiers.mainWindowTitle]
    XCTAssertTrue(main.waitForExistence(timeout: 10), "Ready window not presented")
    return (harness, main)
  }

  /// Drives one dictation via the same hotkey path the pipeline tests use, then
  /// waits for the harness echo (`recentDictations.entries.first?.text`) to show
  /// the canned transcript — at which point the entry the ready screen renders
  /// is in place.
  private func driveDictation(via harness: XCUIElement) {
    harness.buttons[UITestIdentifiers.hotkeyPressButton].click()
    harness.buttons[UITestIdentifiers.hotkeyReleaseButton].click()
    let echo = harness.descendants(matching: .any)
      .matching(identifier: UITestIdentifiers.transcriptEchoLabel).firstMatch
    waitForLabel(echo, equals: UITestIdentifiers.defaultCannedTranscript)
  }

  /// The Recent row for the canned transcript (the row's VoiceOver label is
  /// "<text>, <relative time>", hence CONTAINS).
  private func recentRow(in main: XCUIElement) -> XCUIElement {
    let rowPredicate = NSPredicate(
      format: "label CONTAINS %@", UITestIdentifiers.defaultCannedTranscript)
    return main.descendants(matching: .any).matching(rowPredicate).firstMatch
  }
}
