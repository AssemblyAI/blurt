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

  func testReadyScreenShowsShortcutAndRecent() {
    mainWindow()

    // The shortcut row: one element naming the bound key in words (the row
    // itself draws it as a keycap) and how to use it.
    let shortcutPredicate = NSPredicate(
      format: "label BEGINSWITH %@", "Shortcut: Right Command.")
    XCTAssertTrue(
      app.descendants(matching: .any).matching(shortcutPredicate).firstMatch
        .waitForExistence(timeout: 10),
      "Ready screen should state the dictation shortcut")

    // The style row is always present — with no custom styles yet its pop-up
    // holds just Default and the "Edit Styles…" item that leads to Settings,
    // where styles are made.
    let main = app.windows[UITestIdentifiers.mainWindowTitle]
    let styles = main.popUpButtons[UITestIdentifiers.styleProfilePickerFromMain]
    XCTAssertTrue(styles.waitForExistence(timeout: 10), "Style pop-up not found")
    // The value is `StyleProfileStore.defaultStyleName`, spelled out because
    // this bundle can't import the engine.
    XCTAssertEqual(
      styles.value as? String, "Default",
      "The style pop-up should start on the Default style")

    // The Recent section, empty on a fresh launch, shows its header and the
    // first-dictation prompt that fills the reserved list area.
    XCTAssertTrue(app.staticTexts["Recent"].exists, "Ready screen should have a Recent section")
    XCTAssertTrue(
      emptyRecentPrompt(in: main).exists,
      "An empty Recent list should prompt the first dictation")

    // The Settings button at the window's foot — the main window's own route
    // to the Settings scene, alongside ⌘, and the menu-bar item.
    XCTAssertTrue(
      main.buttons["Settings"].exists,
      "Ready screen should offer its Settings button")
  }

  /// The style pop-up's menu: the styles, then "Edit Styles…" past a divider.
  /// The separator itself isn't an accessibility element, so what's asserted is
  /// that both kinds of item share the one menu. The menu is dismissed rather
  /// than clicked through — choosing that item opens Settings, which is
  /// `SettingsUITests`' ground.
  func testStylePopUpOffersEditStyles() {
    let main = mainWindow()

    let styles = main.popUpButtons[UITestIdentifiers.styleProfilePickerFromMain]
    XCTAssertTrue(styles.waitForExistence(timeout: 10), "Style pop-up not found")
    styles.click()

    let editPredicate = NSPredicate(format: "title == %@", "Edit Styles…")
    XCTAssertTrue(
      app.menuItems.matching(editPredicate).firstMatch.waitForExistence(timeout: 5),
      "The style menu should offer the route to where styles are edited")
    XCTAssertTrue(app.menuItems["Default"].exists, "The style menu should list the Default style")

    app.typeKey(.escape, modifierFlags: [])
  }

  func testCompletedDictationPopulatesRecentList() {
    let (harness, main) = readyScreenWindows()

    // The Recent list starts empty.
    XCTAssertTrue(
      emptyRecentPrompt(in: main).waitForExistence(timeout: 10),
      "Recent list should start empty")

    driveDictation(via: harness)

    // The completed dictation appears as a Recent row on the ready screen.
    let row = recentRow(in: main)
    XCTAssertTrue(
      row.waitForExistence(timeout: 10),
      "A completed dictation should appear in the ready screen's Recent list")
    XCTAssertFalse(
      emptyRecentPrompt(in: main).exists,
      "The empty-list prompt should be gone once a dictation is recorded")
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
    let echo = harness.anyDescendant(identified: UITestIdentifiers.transcriptEchoLabel)
    waitForLabel(echo, equals: UITestIdentifiers.defaultCannedTranscript)
  }

  /// The empty Recent list's first-dictation prompt, one element whose label
  /// starts "Click into any text field" and goes on to name the bound key.
  private func emptyRecentPrompt(in main: XCUIElement) -> XCUIElement {
    main.descendants(matching: .any)[UITestIdentifiers.recentEmptyPrompt]
  }

  /// The Recent row for the canned transcript (the row's VoiceOver label is
  /// "<text>, <relative time>", hence CONTAINS).
  private func recentRow(in main: XCUIElement) -> XCUIElement {
    let rowPredicate = NSPredicate(
      format: "label CONTAINS %@", UITestIdentifiers.defaultCannedTranscript)
    return main.descendants(matching: .any).matching(rowPredicate).firstMatch
  }
}
