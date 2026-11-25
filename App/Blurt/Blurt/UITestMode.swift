#if UITEST_HOOKS

  import BlurtEngine
  import Foundation

  // Test scaffolding that lets the XCUITest suite drive the real app against
  // deterministic, offline doubles. Gated on the `UITEST_HOOKS` compilation
  // condition (defined for the Debug config, so Xcode, check.sh, and the UI/leak
  // scripts all get it) rather than bare `#if DEBUG`, so `scripts/dev-build.sh`
  // — which strips the condition — produces a clean local build without any of
  // it. Never compiled into the notarized Release build, and even when compiled
  // it only activates under the `-BlurtUITest` launch argument.
  //
  // The doubles stand in for exactly the three pipeline seams that need real
  // hardware / network / Accessibility (mic, transcriber, injector) plus the
  // Keychain-backed key store, so a UI test exercises the full
  // `DictationSession` → `AppCoordinator` render path and the settings flows
  // without any of those external dependencies. Each lives in its own `UITest*`
  // file beside this one; the harness window is `UITestHarnessView`.
  //
  // Accessibility identifiers, the launch argument, and the sentinel API keys
  // live in the shared `UITestIdentifiers` (Shared/UITestIdentifiers.swift),
  // compiled into both this target and the XCUITest bundle.

  /// Whether this process was launched for UI testing. Cheap enough to read on
  /// demand; the test runner sets the flag via `XCUIApplication.launchArguments`.
  enum UITestMode {
    static var isActive: Bool {
      ProcessInfo.processInfo.arguments.contains(UITestIdentifiers.launchArgument)
    }

    /// Whether the runner asked for the forced-ready state (implies `isActive`) so
    /// the main window renders `ReadyView` instead of the setup wizard — the only
    /// way the test host can reach that screen, since it can't grant real TCC
    /// permissions. See `AppDelegate.applicationDidFinishLaunching`.
    static var isReadyStateRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(UITestIdentifiers.readyLaunchArgument)
    }

    /// Whether the runner asked for a sample file to be transcribed at launch
    /// (`transcribeSampleLaunchArgument`).
    static var isTranscribeSampleRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(UITestIdentifiers.transcribeSampleLaunchArgument)
    }

    /// A throwaway history for this run, seeded when the runner asks
    /// (`seedHistoryLaunchArgument`).
    static func historyStore() -> TranscriptStore {
      let store = TranscriptStore(
        url: FileManager.default.temporaryDirectory.appending(path: "blurt-uitest-\(UUID().uuidString).json")
      )
      if ProcessInfo.processInfo.arguments.contains(UITestIdentifiers.seedHistoryLaunchArgument) {
        UITestHistorySeed.seed(store)
      }
      return store
    }
  }

#endif
