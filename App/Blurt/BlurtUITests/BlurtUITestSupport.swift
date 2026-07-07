import XCTest

// The UI-test identifiers, window titles, launch argument, and sentinel API keys
// live in `UITestIdentifiers` (App/Blurt/Shared/UITestIdentifiers.swift), which
// is compiled into both the Blurt app target and this XCUITest bundle. The
// values are declared once there and referenced from both sides, so the app's
// production views and these suites can no longer drift out of sync.

extension UITestIdentifiers {
  /// The Settings window's title, supplied by the framework for the `Settings`
  /// scene as "<bundle name> Settings" — the app never declares it in source, so
  /// only this XCUITest bundle references it (hence a test-bundle-only constant
  /// rather than one in the shared, app-compiled file).
  static let settingsWindowTitle = "Blurt Settings"
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
    app.launchArguments += [UITestIdentifiers.launchArgument]
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
    let settings = app.windows[UITestIdentifiers.settingsWindowTitle]
    if !settings.exists {
      app.typeKey(",", modifierFlags: .command)
    }
    XCTAssertTrue(
      settings.waitForExistence(timeout: timeout),
      "Settings window did not open after ⌘,")
    return settings
  }

  /// The UI-test harness window. In UI-test mode it's the only window presented
  /// at launch (the main window is suppressed — see `App.swift` /
  /// `mainWindowLaunchBehavior`), so it comes up frontmost and key with its
  /// controls directly clickable — no sibling windows to close first.
  func harnessWindow(timeout: TimeInterval = 10) -> XCUIElement {
    let harness = app.windows[UITestIdentifiers.harnessWindowTitle]
    XCTAssertTrue(
      harness.waitForExistence(timeout: timeout),
      "UI test harness window was not presented")
    return harness
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
