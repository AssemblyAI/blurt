/// The single source of truth for UI-test–facing strings: accessibility
/// identifiers, window titles, the launch argument, and the offline sentinel API
/// keys. Compiled into *both* the Blurt app target and the BlurtUITests bundle
/// (see `project.yml` — the file is listed under both targets' `sources`), so the
/// app's production views and the XCUITest suite reference the same constants
/// instead of hand-duplicating literals across three places. Each target compiles
/// its own copy from this one file, so editing here updates both at once.
///
/// Plain `Sendable` string constants, so they're readable from any isolation in
/// either target (the app defaults declarations to `@MainActor`; the test bundle
/// does not).
enum UITestIdentifiers {
  /// Passed to `XCUIApplication.launchArguments` to put the app in UI-test mode
  /// (offline stub pipeline + harness window); read by `UITestMode`.
  static let launchArgument = "-BlurtUITest"
  /// Opt-in flag that forces the fully-configured "ready" state (saved key + all
  /// permissions granted) so the main window renders `ReadyView` instead of the
  /// setup wizard — the test host can't grant real TCC permissions. Read by
  /// `UITestMode.isReadyStateRequested`; opted into per test.
  static let readyLaunchArgument = "-BlurtUITestReady"

  // Window titles the XCUITest suite queries, sourced from the `Window(_:id:)`
  // declarations in `App.swift`. (The framework-derived Settings title, which the
  // app never declares, is a test-bundle-only constant in BlurtUITestSupport.)
  static let mainWindowTitle = "Blurt"
  static let harnessWindowTitle = "Blurt UI Test Harness"
  /// The harness `Window`'s scene id.
  static let harnessWindowID = "uitest.harness"

  // Test-harness controls (set in `UITestSupport.swift`).
  static let transcriptField = "uitest.transcript"
  static let setKeyButton = "uitest.setKey"
  static let startButton = "uitest.start"
  static let stopButton = "uitest.stop"
  static let cancelButton = "uitest.cancel"
  static let hotkeyPressButton = "uitest.hotkeyPress"
  static let hotkeyReleaseButton = "uitest.hotkeyRelease"
  static let statusLabel = "uitest.status"
  static let pastedLabel = "uitest.pasted"
  static let transcriptEchoLabel = "uitest.transcriptEcho"

  // Settings/wizard controls (set on the step views).
  static let apiKeyField = "settings.apiKey.field"
  static let apiKeyReveal = "settings.apiKey.reveal"
  static let apiKeySave = "settings.apiKey.save"
  static let apiKeyCancel = "settings.apiKey.cancel"
  static let apiKeyChange = "settings.apiKey.change"
  static let apiKeySavedStatus = "settings.apiKey.savedStatus"
  static let apiKeyError = "settings.apiKey.error"
  static let keyTermsField = "settings.keyTerms.field"
  static let hotkeyPicker = "settings.hotkey.picker"
  static let soundPicker = "settings.sound.picker"
  static let developerToggle = "settings.developer.toggle"

  /// The dictation overlay pill (`OverlayView`).
  static let overlayPill = "overlay.pill"

  /// The stub transcriber's default canned transcript
  /// (`UITestState.cannedTranscript`); the suites assert against it rather than
  /// typing a custom one (a headless runner can't give the harness's text field
  /// keyboard focus), so both sides must agree on the value.
  static let defaultCannedTranscript = "hello world"

  // Sentinel API keys the offline UI-test validation recognizes
  // (`UITestKeyValidation`); the suite types these to drive the settings paths.
  static let validAPIKey = "uitest-valid-key"
  static let invalidAPIKey = "uitest-invalid-key"
  static let unreachableAPIKey = "uitest-unreachable-key"
}
