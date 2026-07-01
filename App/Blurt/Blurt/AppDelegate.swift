import AppKit
import BlurtEngine
import Foundation
import Observation
import Sentry

/// Owns the long-lived models and runs launch-time setup. The setup wizard and
/// settings UI are SwiftUI `Window` scenes (see `BlurtApp` / `MainWindowRoot`
/// / `SettingsWindowRoot`), so this delegate no longer manages any window itself
/// — it just exposes the models the scenes read and keeps the app alive when the
/// windows are closed.
///
/// `@Observable` so `MainWindowRoot` re-renders when `coordinator` /
/// `wizardController` are assigned: they're created in `applicationDidFinishLaunching`,
/// which can land *after* the window scene's first render — without observation
/// the scene would keep showing its empty fallback and never refresh.
@Observable
final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor private(set) var coordinator: AppCoordinator?
  @MainActor private(set) var wizardController: WizardController?
  @ObservationIgnored @MainActor private lazy var autoUpdater = AutoUpdater(
    presentingWindow: { [unowned self] in updatePromptHostWindow() }
  )

  /// Opens a window scene by id. The `openWindow` action lives in SwiftUI, so the
  /// scenes capture it here (see `BlurtApp`) to give AppKit entry points —
  /// notably a Dock click with no open windows — a way to reopen a window even on
  /// a configured launch where none was shown.
  @ObservationIgnored @MainActor var openWindowByID: (@MainActor (String) -> Void)?

  /// Brings the main window forward (showing the wizard or the ready screen).
  @MainActor func openMainWindow() { openWindowByID?(MainWindow.id) }

  /// Surfaces the main window *and* makes the app frontmost. Shared by the menu
  /// bar's "Open Blurt", the missing-key hotkey nudge, and the permission-revoked
  /// kick-back: all need the app pulled in front of whatever the user was in.
  ///
  /// When the window already exists (the app is just running in the background,
  /// possibly minimized to the Dock), raise it directly: `openWindow(id:)` focuses
  /// the scene but won't deminiaturize a window the user sent to the Dock or
  /// reliably re-front an existing one. Only when no main window exists (the user
  /// closed it) do we recreate it via the scene.
  @MainActor func surfaceMainWindow() {
    NSApp.activate()
    if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == MainWindow.id }) {
      main.deminiaturize(nil)
      main.makeKeyAndOrderFront(nil)
    } else {
      openMainWindow()
    }
  }

  /// Surfaces the main window and returns it to host the update prompt's sheet
  /// (see `AutoUpdater.runAlert`). The main window scene always exists by the
  /// time an update check completes, so this resolves to it (with the generic
  /// `canBecomeMain` window as a belt-and-suspenders fallback).
  @MainActor func updatePromptHostWindow() -> NSWindow {
    surfaceMainWindow()
    return NSApp.windows.first { $0.identifier?.rawValue == MainWindow.id }
      ?? NSApp.windows.first { $0.canBecomeMain }!
  }

  /// True once the launch-time activation has run.
  @ObservationIgnored @MainActor private var didActivateAtLaunch = false

  /// Pulls Blurt frontmost for its initial window presentation. Called from
  /// the main window's `onAppear` rather than `applicationDidFinishLaunching`:
  /// at launch-finish the SwiftUI `Window` scene's NSWindow isn't on screen yet,
  /// so activating then races the window's creation and it can come up behind
  /// whatever the user was in. By `onAppear` the window exists, so activation
  /// reliably brings it forward. Idempotent — only the first call (the launch
  /// presentation) activates; later re-appears (Dock reopen, the hotkey and
  /// revocation nudges) activate through their own paths.
  ///
  /// `NSApp.activate()` alone is enough for a normal launch (double-click / Dock /
  /// `open`), where LaunchServices grants the new process foreground-activation
  /// rights. It is *not* enough after a self-update relaunch: AppUpdater's install
  /// script restarts Blurt by exec'ing the bundle's binary directly (not through
  /// LaunchServices), so macOS withholds those rights and the cooperative
  /// `activate()` silently no-ops — the window comes up behind whatever the user was
  /// in. `orderFrontRegardless()` raises the window to the front of its level even
  /// while the app is inactive, covering that case (it's the same call the overlay
  /// pill uses to surface without activating). Targets the one `canBecomeMain`
  /// window — the main scene — rather than the non-activating overlay panel.
  @MainActor func activateAtLaunchIfNeeded() {
    guard !didActivateAtLaunch else { return }
    didActivateAtLaunch = true
    NSApp.activate()
    if let main = NSApp.windows.first(where: { $0.canBecomeMain }) {
      main.makeKeyAndOrderFront(nil)
      main.orderFrontRegardless()
    }
  }

  @MainActor
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Crash/error reporting. Started as early as possible so launch-time failures
    // are captured. Release-only: local dev runs the Debug configuration, and we
    // don't want developer crashes/usage polluting production Sentry data. (The
    // `SentrySDK.capture` calls in `AppCoordinator` are safe no-ops when the SDK
    // was never started, so they self-disable in Debug too.) Blurt never sends
    // dictation text or transcripts to Sentry; `sendDefaultPii` is left off so we
    // don't attach the reporter's IP either — crash grouping doesn't need it, and
    // a dictation app shouldn't ship identifying data it doesn't use. The
    // diagnostics this does send are disclosed in README.md and SECURITY.md.
    #if !DEBUG
      SentrySDK.start { options in
        options.dsn = "https://8191e48535bcc3fd861f912ae8735e18@o4509792651902976.ingest.us.sentry.io/4511634026004480"
        // Pinned rather than left to the SDK's auto-detection: we only start
        // Sentry in Release builds (see the `#if !DEBUG`), so every reporting
        // session is production, and release-health charts filter on this.
        options.environment = "production"
        options.sendDefaultPii = false
      }
    #endif

    // No permission prompts fire at launch. Accessibility (and Microphone) are
    // requested only when the user taps the matching button in the setup
    // screen's permission rows — see `PermissionsStepView`.
    // Pressing the hotkey with no key saved brings the main window forward (and
    // activates the app, since the user is in another app when they press it) so
    // they can add a key via the wizard. `openWindowByID` is captured by the
    // scene's command views at launch, so it's set by the time the hotkey fires.
    // The overlay pill isn't built here — `AppCoordinator` creates it lazily in
    // `showOverlay()` once the app is fully configured.
    let onMissingAPIKey: @MainActor () -> Void = { [weak self] in self?.surfaceMainWindow() }
    let coord: AppCoordinator
    #if UITEST_HOOKS
      // Under UI testing, compose the app with offline stub collaborators and an
      // in-memory key store so the suite drives the real pipeline without a mic,
      // network, Accessibility, or the production Keychain item.
      if UITestMode.isActive {
        // Reset to a clean, preinstall state so every UI-test launch is
        // deterministic regardless of prior runs: clear the persisted settings
        // (trigger key, sound pack, key terms) back to their defaults. The API
        // key already uses an in-memory store, and window state is handled test-
        // side. Guarded by UITestMode (only the runner passes -BlurtUITest), so a
        // normal launch is untouched — running the UI tests locally does reset
        // these, by design.
        let defaults = UserDefaults.standard
        for key in [TriggerKeyStore.defaultsKey, SoundPackStore.defaultsKey, KeyTermsStore.defaultsKey] {
          defaults.removeObject(forKey: key)
        }
        coord = AppCoordinator(
          onMissingAPIKey: onMissingAPIKey,
          components: .uiTest(),
          keyStore: InMemoryAPIKeyStore(),
          isUITesting: true)
      } else {
        coord = AppCoordinator(onMissingAPIKey: onMissingAPIKey)
      }
    #else
      coord = AppCoordinator(onMissingAPIKey: onMissingAPIKey)
    #endif
    self.coordinator = coord

    // Start the coordinator *before* building the wizard: `start()` creates the
    // dictation key tap (without installing it — that would prompt for
    // permissions at launch), and `WizardController.init` calls `showOverlay()`
    // on a configured launch, which is what actually installs the tap. If the
    // wizard ran first the tap wouldn't exist yet and would never come up.
    coord.start()

    // Created before the run loop presents any scene, so `MainWindowRoot` always
    // finds it. On a configured launch its init reveals the overlay pill even
    // though no window is shown. `onNeedsForeground` fires when a configured app
    // loses a requirement (e.g. a revoked permission) so the user is pulled back
    // into onboarding even if every window was closed.
    self.wizardController = WizardController(
      coordinator: coord,
      onNeedsForeground: { [weak self] in self?.surfaceMainWindow() })

    #if UITEST_HOOKS
      // Build the overlay pill up front under UI testing so the suite can observe
      // it during dictation. Normally `WizardController` reveals it only on the
      // transition into "ready" (every permission granted + a key saved), but the
      // test runner can't grant real TCC permissions, so readiness never flips and
      // the pill would never appear. Building it here lets the live pipeline drive
      // the pill through `render(_:)` exactly as it does in production — the key
      // tap's `ensureRunning()` simply no-ops without Accessibility trust, and the
      // wizard's not-ready poll leaves this pill in place (it only hides on a
      // ready→not-ready *transition*, which never occurs here).
      if UITestMode.isActive {
        coord.showOverlay()
      }
    #endif

    // The main window is presented at launch (`.defaultLaunchBehavior(.presented)`),
    // but presenting a window doesn't make the app frontmost. Activation happens
    // in the window's `onAppear` (via `activateAtLaunchIfNeeded`), not here: at
    // this point the scene's NSWindow isn't on screen yet, so activating now
    // races its creation and the window can open behind whatever the user was in.

    // Self-update: check GitHub Releases at launch and, if a newer signed build
    // exists, prompt to install + relaunch (Install and Relaunch / Later).
    // Best-effort — failures are logged and never block launch. See `AutoUpdater`.
    Task { await autoUpdater.checkAndPrompt() }

    #if UITEST_HOOKS
      // Leak-exercise mode (scripts/leaks.sh): drive a few dictation cycles so the
      // Leaks instrument sees the real app-shell objects (coordinator, overlay,
      // menu-bar status, windows, phase observers) built up and torn down —
      // coverage the engine-only weak-reference tests can't reach. Gated behind an
      // env var so ordinary Debug and UI-test runs are unaffected; only meaningful
      // alongside -BlurtUITest, whose stub pipeline makes it offline/deterministic.
      if ProcessInfo.processInfo.environment["BLURT_LEAK_EXERCISE"] == "1" {
        Task { await self.runLeakExercise(coord) }
      }
    #endif
  }

  #if UITEST_HOOKS
    /// Runs several stubbed dictation cycles through the live coordinator so a
    /// Leaks-instrument recording exercises the full app-shell object graph. See
    /// the call site in `applicationDidFinishLaunching` and `scripts/leaks.sh`.
    @MainActor
    private func runLeakExercise(_ coord: AppCoordinator) async {
      coord.saveAPIKey("uitest-valid-key")  // clear the missing-key gate
      // Build/enable the key tap's object graph, then drive cycles *through the
      // tap* (gate + callbacks), so the leak run covers the real dictation-key
      // path — not just the session. (The tap can't create its CGEventTap without
      // Accessibility trust, but its gate/callback graph is still exercised.)
      coord.showOverlay()
      for _ in 0..<5 {
        coord.simulateDictationPressForTesting()
        try? await Task.sleep(for: .milliseconds(120))  // let press() reach .recording
        coord.simulateDictationReleaseForTesting()
        try? await Task.sleep(for: .milliseconds(180))  // let transcribe→inject settle
      }
      coord.hideOverlay()
    }
  #endif

  @MainActor
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Blurt keeps running with the overlay pill after its window is closed;
    // the window reopens via ⌘, / the Dock.
    return false
  }

  /// Bring Blurt's window to the front on relaunch / Dock click. The Dock (or
  /// relaunching the app) is the primary way back to the window once it's closed
  /// or after a quiet, configured launch — the menu bar item's "Open Blurt" is a
  /// secondary path, but the notch can hide that item, so the Dock stays the
  /// guaranteed one.
  ///
  /// `NSApp.activate()` is the important part: `openWindow` focuses the scene but
  /// doesn't make the app frontmost, so without it the window opens *behind*
  /// whatever the user was in. SwiftUI also doesn't reliably reopen a closed
  /// `Window` scene on its own, so we open it explicitly when none is visible.
  @MainActor
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    NSApp.activate()
    if !flag { openMainWindow() }
    return true
  }
}
