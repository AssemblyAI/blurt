import XCTest

// The window helpers every suite shares: opening Settings and picking a pane,
// bringing the harness or the main window frontmost, and waiting on a read-out.
// (Driving the API-key sheet is in `BlurtUITestCase+APIKeySheet.swift`.)
extension BlurtUITestCase {
  /// Opens the Settings window via the standard ⌘, command and returns its
  /// General pane. Production restores the last-used pane, per the macOS HIG;
  /// tests explicitly select General here so each case starts deterministically.
  /// The command is app-global, so it works regardless of which window has
  /// focus, and it's sent even when Settings is already open: that raises it
  /// over the harness a test clicked since, rather than driving its toolbar
  /// from behind. Unlike the harness, Settings opens frontmost via ⌘,, so its
  /// controls are hittable without closing the other windows.
  @discardableResult
  func openSettingsWindow(timeout: TimeInterval = 10) -> XCUIElement {
    let paneTitles = [
      UITestIdentifiers.generalSettingsTab,
      UITestIdentifiers.keysSettingsTab,
      UITestIdentifiers.soundsSettingsTab,
      UITestIdentifiers.readAloudSettingsTab,
      UITestIdentifiers.stylesSettingsTab,
      UITestIdentifiers.vocabularySettingsTab,
      UITestIdentifiers.advancedSettingsTab,
    ]
    let settings = app.windows.matching(NSPredicate(format: "title IN %@", paneTitles)).firstMatch
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(
      settings.waitForExistence(timeout: timeout),
      "Settings window did not open after ⌘,"
    )
    guard settings.title != UITestIdentifiers.generalSettingsTab else {
      return settings
    }
    return selectSettingsTab(settings, named: UITestIdentifiers.generalSettingsTab)
  }

  /// Selects a Settings pane (a `TabView` tab in the preferences toolbar) by its
  /// visible name. macOS exposes a preference tab as a radio button or a plain
  /// button depending on the OS build (a button on macOS 26), so one query
  /// takes either: waiting out a radio that never comes left the button only
  /// a few seconds, too few on a loaded CI runner. Returns a fresh proxy for
  /// the settings window: selecting a pane retitles the window to the pane's
  /// name, so a proxy captured before the switch (e.g. `openSettingsWindow()`'s)
  /// goes stale — scope follow-up queries to the returned one.
  @discardableResult
  func selectSettingsTab(_ window: XCUIElement, named name: String) -> XCUIElement {
    let tab = window.toolbars.firstMatch.descendants(matching: .any)
      .matching(
        NSPredicate(
          format: "(elementType == %d OR elementType == %d) AND title == %@",
          XCUIElement.ElementType.radioButton.rawValue,
          XCUIElement.ElementType.button.rawValue,
          name
        )
      )
      .firstMatch
    guard tab.waitForExistence(timeout: 10) else {
      // What the window held instead, so a CI failure says why without the
      // .xcresult.
      XCTFail("Settings tab '\(name)' not found in:\n\(window.debugDescription)")
      return app.windows[name]
    }
    tab.click()
    return app.windows[name]
  }

  /// The UI-test harness window (auto-presented at launch in test mode). Closes
  /// the other windows so the harness is frontmost and its buttons are clickable
  /// (see `closeWindows`).
  func harnessWindow(timeout: TimeInterval = 10) -> XCUIElement {
    frontmostWindow(
      titled: UITestIdentifiers.harnessWindowTitle,
      "UI test harness window was not presented",
      timeout: timeout
    )
  }

  /// The main window (the setup wizard, or `ReadyView` under the ready-state
  /// flag), brought frontmost by closing the sibling harness/Settings windows so
  /// its controls are hittable — the same treatment `harnessWindow()` gives the
  /// harness.
  @discardableResult
  func mainWindow(timeout: TimeInterval = 10) -> XCUIElement {
    frontmostWindow(
      titled: UITestIdentifiers.mainWindowTitle,
      "Main window was not presented",
      timeout: timeout
    )
  }

  /// The two windows a ready-state launch presents, both left open. The harness
  /// sits in the top-leading corner (see `BlurtApp`) so it never overlaps the
  /// centered ready window: a test can drive the harness — a dictation, a live
  /// recording's turns — and read the result on the still-open ready screen,
  /// with no closing and reopening.
  func readyScreenWindows() -> (harness: XCUIElement, main: XCUIElement) {
    let harness = app.windows[UITestIdentifiers.harnessWindowTitle]
    XCTAssertTrue(harness.waitForExistence(timeout: 10), "Harness window not presented")
    let main = app.windows[UITestIdentifiers.mainWindowTitle]
    XCTAssertTrue(main.waitForExistence(timeout: 10), "Ready window not presented")
    return (harness, main)
  }

  /// Waits for the window titled `title`, then closes its siblings so it is
  /// frontmost and its controls are hittable (see `closeWindows`).
  private func frontmostWindow(
    titled title: String, _ message: String, timeout: TimeInterval
  ) -> XCUIElement {
    let window = app.windows[title]
    XCTAssertTrue(window.waitForExistence(timeout: timeout), message)
    closeWindows(except: title)
    return window
  }

  /// Closes every app window except the one titled `keepTitle`. The app presents
  /// several windows at launch (wizard/ready, the UI-test harness, and any
  /// Settings window macOS restored), all centered and overlapping — and XCUITest
  /// can't hit a control that sits under another window, nor does a click on a
  /// covered button register. Closing the siblings leaves `keepTitle` frontmost
  /// and fully interactable. Closes one per pass (front-most first — only its
  /// close button is un-occluded), re-querying until none remain. The app keeps
  /// running with its windows closed
  /// (`applicationShouldTerminateAfterLastWindowClosed` returns false).
  private func closeWindows(except keepTitle: String) {
    for _ in 0..<5 {
      let target = (0..<app.windows.count)
        .map { app.windows.element(boundBy: $0) }
        .first { window in
          window.title != keepTitle
            && window.buttons[XCUIIdentifierCloseWindow].firstMatch.isHittable
        }
      guard let target else { break }
      target.buttons[XCUIIdentifierCloseWindow].firstMatch.click()
    }
  }

  /// Waits until `element`'s label *or* value equals `expected`, failing the test
  /// otherwise. Both are checked because XCUITest surfaces a SwiftUI `Text`'s
  /// string as the element's accessibility `value` (not its `label`) — the
  /// harness's status/pasted read-outs are plain `Text`s — while controls like
  /// buttons expose the same string as their `label`. Matching either keeps this
  /// helper usable for both without the caller knowing which attribute carries
  /// the string.
  func waitForLabel(
    _ element: XCUIElement,
    equals expected: String,
    timeout: TimeInterval = 10,
    _ message: String = ""
  ) {
    let predicate = NSPredicate(format: "label == %@ OR value == %@", expected, expected)
    let exp = XCTNSPredicateExpectation(predicate: predicate, object: element)
    let result = XCTWaiter().wait(for: [exp], timeout: timeout)
    let failure =
      message.isEmpty
      ? "Expected label/value '\(expected)', got label='\(element.label)' value='\(String(describing: element.value))'"
      : message
    XCTAssertEqual(result, .completed, failure)
  }
}
