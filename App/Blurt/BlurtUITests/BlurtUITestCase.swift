import XCTest

// The UI-test identifiers, window titles, launch argument, and sentinel API keys
// live in `UITestIdentifiers` (App/Blurt/Shared/UITestIdentifiers.swift), which
// is compiled into both the Blurt app target and this XCUITest bundle. The
// values are declared once there and referenced from both sides, so the app's
// production views and these suites can no longer drift out of sync.

/// Base case that launches Blurt in UI-test mode before each test and tears it
/// down after. Subclasses get a ready `app` plus a couple of shared helpers
/// (`BlurtUITestCase+Windows`, `BlurtUITestCase+HarnessDriving`).
///
/// `@MainActor`-isolated because the whole XCUIAutomation API (`XCUIApplication`,
/// `XCUIElement`, the element queries) is main-actor-isolated under Swift 6.
/// XCTest already drives these lifecycle methods and the test bodies on the main
/// thread, so the isolation is accurate; annotating it silences the otherwise
/// pervasive "main actor-isolated … from a nonisolated context" warnings.
/// Subclasses inherit the isolation, so they don't repeat the annotation.
///
/// Every suite subclasses this base, so it can't be final (`final_test_case`).
@MainActor
class BlurtUITestCase: XCTestCase {  // swiftlint:disable:this final_test_case
  // `lazy` (not the classic IUO) keeps the property non-optional: `setUp`
  // replaces it with a fresh proxy before every test, and the lazy initial
  // value is evaluated in a @MainActor accessor, which the nonisolated
  // inherited XCTestCase initializers couldn't do for a stored default.
  // Every subclass's tests drive it, so it can't be private
  // (`test_case_accessibility`).
  lazy var app = XCUIApplication()  // swiftlint:disable:this test_case_accessibility

  /// Launch arguments a subclass wants added on top of the base `-BlurtUITest`
  /// flag before the app launches in `setUp`. Empty by default; `ReadyViewUITests`
  /// overrides it to opt into the ready-state flag. Overridden by subclasses,
  /// so it can be neither private nor moved to an extension
  /// (`test_case_accessibility`).
  var extraLaunchArguments: [String] { [] }  // swiftlint:disable:this test_case_accessibility

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
    app.launchArguments += [UITestIdentifiers.launchArgument] + extraLaunchArguments
    app.launch()
  }

  override func tearDown() async throws {
    app.terminate()
    try await super.tearDown()
  }
}
