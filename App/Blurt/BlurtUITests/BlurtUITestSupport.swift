import XCTest

/// Identifiers, window titles, and launch flags shared by the XCUITest suites.
///
/// These mirror the values the app declares (`UITestID` / `UITestKeys` in the
/// Blurt target, and the SwiftUI `Window` titles). The test bundle is a separate
/// module and can't import the app's internal symbols, so the strings are
/// duplicated here — keep the two in sync if either side changes.
enum UITestIDs {
  /// Passed to `XCUIApplication.launchArguments` to put the app in UI-test mode
  /// (offline stub pipeline + harness window). Matches `UITestMode.launchArgument`.
  static let launchArgument = "-BlurtUITest"

  /// Additional flag that forces the app into its fully-configured "ready" state
  /// (a saved key + all permissions granted), so the main window shows
  /// `ReadyView` instead of the setup wizard. The XCUITest host can't grant real
  /// TCC permissions, so this is the only way to render the ready screen. Matches
  /// `UITestMode.readyStateArgument`; opt-in per test, so wizard-based tests are
  /// unaffected.
  static let readyLaunchArgument = "-BlurtUITestReady"

  // Window titles. Main and harness come from the first argument of their
  // SwiftUI `Window(_:id:)` declarations; the settings title is supplied by
  // the framework for the `Settings` scene — "<bundle name> Settings" — so it
  // tracks `CFBundleName`/`CFBundleDisplayName` (project.yml), not any string
  // in the app source.
  static let mainWindowTitle = "Blurt"
  static let settingsWindowTitle = "Blurt Settings"
  static let harnessWindowTitle = "Blurt UI Test Harness"

  // Settings controls (`accessibilityIdentifier`s on the step views).
  static let apiKeyField = "settings.apiKey.field"
  static let apiKeyReveal = "settings.apiKey.reveal"
  static let apiKeySave = "settings.apiKey.save"
  static let apiKeyCancel = "settings.apiKey.cancel"
  static let apiKeyChange = "settings.apiKey.change"
  static let apiKeySavedStatus = "settings.apiKey.savedStatus"
  static let apiKeyError = "settings.apiKey.error"
  static let hotkeyPicker = "settings.hotkey.picker"
  static let soundPicker = "settings.sound.picker"
  static let developerToggle = "settings.developer.toggle"

  // Test-harness controls (`UITestID` in UITestSupport.swift).
  static let setKeyButton = "uitest.setKey"
  static let startButton = "uitest.start"
  static let stopButton = "uitest.stop"
  static let cancelButton = "uitest.cancel"
  static let hotkeyPressButton = "uitest.hotkeyPress"
  static let hotkeyReleaseButton = "uitest.hotkeyRelease"
  static let statusLabel = "uitest.status"
  static let pastedLabel = "uitest.pasted"
  static let transcriptEchoLabel = "uitest.transcriptEcho"

  // The dictation overlay pill (`OverlayView`), a floating panel driven by the
  // live pipeline. Its accessibility label is `OverlayUIState.accessibilityLabel`.
  static let overlayPill = "overlay.pill"

  // Sentinel API keys the offline submit path recognizes (`UITestKeys`).
  static let invalidAPIKey = "uitest-invalid-key"
  static let unreachableAPIKey = "uitest-unreachable-key"
}

/// Base case that launches Blurt in UI-test mode before each test and tears it
/// down after. Subclasses get a ready `app` plus a couple of shared helpers.
///
/// `@MainActor`-isolated because the whole XCUIAutomation API (`XCUIApplication`,
/// `XCUIElement`, the element queries) is main-actor-isolated under Swift 6.
/// XCTest already drives these lifecycle methods and the test bodies on the main
/// thread, so the isolation is accurate; annotating it silences the otherwise
/// pervasive "main actor-isolated … from a nonisolated context" warnings.
/// Subclasses inherit the isolation, so they don't repeat the annotation.
@MainActor
class BlurtUITestCase: XCTestCase {
  var app: XCUIApplication!

  /// Launch arguments a subclass wants added on top of the base `-BlurtUITest`
  /// flag before the app launches in `setUp`. Empty by default; `ReadyViewUITests`
  /// overrides it to opt into the ready-state flag.
  var extraLaunchArguments: [String] { [] }

  // The async lifecycle overrides (not the sync `setUpWithError`): on a
  // @MainActor subclass, only the async variants can carry the main-actor
  // isolation without clashing with XCTestCase's nonisolated declarations, and
  // the suspension point lets the body run on the main actor — where the
  // @MainActor `app` and the XCUIAutomation API must be touched.
  override func setUp() async throws {
    try await super.setUp()
    // Stop at the first failed assertion in a test: once an expected element is
    // missing, the follow-on steps just produce noise.
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments += [UITestIDs.launchArgument] + extraLaunchArguments
    app.launch()
  }

  override func tearDown() async throws {
    app?.terminate()
    app = nil
    try await super.tearDown()
  }

  /// Opens the Settings window via the standard ⌘, command and returns it. The
  /// command is app-global, so it works regardless of which window has focus.
  /// (Unlike the harness, Settings opens frontmost via ⌘,, so its controls are
  /// hittable without closing the other windows.)
  @discardableResult
  func openSettingsWindow(timeout: TimeInterval = 10) -> XCUIElement {
    let settings = app.windows[UITestIDs.settingsWindowTitle]
    if !settings.exists {
      app.typeKey(",", modifierFlags: .command)
    }
    XCTAssertTrue(
      settings.waitForExistence(timeout: timeout),
      "Settings window did not open after ⌘,")
    return settings
  }

  /// The UI-test harness window (auto-presented at launch in test mode). Closes
  /// the other windows so the harness is frontmost and its buttons are clickable
  /// (see `closeWindows`).
  func harnessWindow(timeout: TimeInterval = 10) -> XCUIElement {
    let harness = app.windows[UITestIDs.harnessWindowTitle]
    XCTAssertTrue(
      harness.waitForExistence(timeout: timeout),
      "UI test harness window was not presented")
    closeWindows(except: UITestIDs.harnessWindowTitle)
    return harness
  }

  /// The main window (the setup wizard, or `ReadyView` under the ready-state
  /// flag), brought frontmost by closing the sibling harness/Settings windows so
  /// its controls are hittable — the same treatment `harnessWindow()` gives the
  /// harness.
  @discardableResult
  func mainWindow(timeout: TimeInterval = 10) -> XCUIElement {
    let main = app.windows[UITestIDs.mainWindowTitle]
    XCTAssertTrue(
      main.waitForExistence(timeout: timeout),
      "Main window was not presented")
    closeWindows(except: UITestIDs.mainWindowTitle)
    return main
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
        .first {
          $0.title != keepTitle
            && $0.buttons[XCUIIdentifierCloseWindow].firstMatch.isHittable
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
    _ element: XCUIElement, equals expected: String, timeout: TimeInterval = 10,
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
