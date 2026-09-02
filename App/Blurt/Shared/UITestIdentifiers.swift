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
  // declarations in `App.swift`.
  static let mainWindowTitle = "Blurt"
  static let harnessWindowTitle = "Blurt UI Test Harness"
  /// The harness `Window`'s scene id.
  static let harnessWindowID = "uitest.harness"

  // The Settings panes' tab labels (`SettingsWindowRoot` renders them; the
  // XCUITest suite clicks them). macOS also titles a preferences window after
  // its selected pane, so the General label doubles as the Settings window's
  // opening title (see `settingsWindowTitle` in BlurtUITestSupport).
  static let generalSettingsTab = "General"
  static let advancedSettingsTab = "Advanced"

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
  // The API-key row and the sheet it opens (`APIKeyStepView`). `connect` /
  // `change` are the same row button under its two titles; the rest live in the
  // sheet.
  static let apiKeyConnect = "settings.apiKey.connect"
  static let apiKeyChange = "settings.apiKey.change"
  static let apiKeyNotConnected = "settings.apiKey.notConnected"
  static let apiKeySavedStatus = "settings.apiKey.savedStatus"
  static let apiKeyField = "settings.apiKey.field"
  static let apiKeyReveal = "settings.apiKey.reveal"
  static let apiKeyGetKey = "settings.apiKey.getKey"
  static let apiKeySave = "settings.apiKey.save"
  static let apiKeyCancel = "settings.apiKey.cancel"
  static let apiKeyError = "settings.apiKey.error"
  static let keyTermsField = "settings.keyTerms.field"
  static let hotkeyPicker = "settings.hotkey.picker"
  static let micPicker = "settings.mic.picker"
  static let soundPicker = "settings.sound.picker"
  static let developerToggle = "settings.developer.toggle"
  static let enhancedTranscriptsToggle = "settings.enhancedTranscripts.toggle"
  static let updateCheck = "settings.update.check"
  /// The Advanced pane's "Reset…" button (`SettingsWindowRoot`'s reset section).
  /// Only the row button is identified: the confirmation it opens is an alert,
  /// whose buttons the suite addresses by title.
  static let installReset = "settings.reset.button"
  // The Styles section and the sheet it opens (`SettingsWindowRoot`). The Edit
  // buttons are per-profile, so they are indexed by row rather than named one
  // by one — the identifier has to be distinct per control, and the profiles
  // themselves are user-named.
  static let styleProfileAdd = "settings.styleProfiles.add"
  static let styleProfileName = "settings.styleProfiles.name"
  static let styleProfileInstructions = "settings.styleProfiles.instructions"
  static let styleProfileSave = "settings.styleProfiles.save"
  static let styleProfileCancel = "settings.styleProfiles.cancel"
  static let styleProfileDelete = "settings.styleProfiles.delete"
  static func styleProfileEdit(_ index: Int) -> String { "settings.styleProfiles.edit.\(index)" }

  /// The main window's style switcher (`ReadyView`): a single pop-up whose
  /// items are Default, then each defined profile, then "Edit Styles…" below a
  /// divider. It needs an identifier because everything else about it is
  /// user-named — the pop-up's own value is whichever style is in effect, so
  /// there is no stable label to address it by.
  static let styleProfilePickerFromMain = "ready.styleProfile.picker"

  /// The dictation overlay pill (`OverlayView`).
  static let overlayPill = "overlay.pill"

  /// The harness's pipeline-status read-out values (`UITestHarnessView.statusText`,
  /// a projection of `MenuBarStatus`). Both sides name them from here for the same
  /// reason as `defaultCannedTranscript`: they're compared as strings, so a rename
  /// on one side alone still compiles and every assertion instead burns its full
  /// `waitForLabel` timeout — three times over, once per xctestplan retry.
  static let statusIdle = "idle"
  static let statusRecording = "recording"
  static let statusTranscribing = "transcribing"

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
