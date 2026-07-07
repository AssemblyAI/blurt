import AppKit
import BlurtEngine
import Foundation
import Observation

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
  private(set) var coordinator: AppCoordinator?
  private(set) var wizardController: WizardController?

  /// Backs both the app-menu "Check for Updates…" command and the menu-bar
  /// item, so a check from either place runs through the same controller and
  /// can't stack two result alerts. `lazy` so its bundle-version parse stays off
  /// the launch path — it's built on first check, not at startup.
  @ObservationIgnored lazy var updateCheckModel = UpdateCheckModel()

  /// Opens a window scene by id. The `openWindow` action lives in SwiftUI, so
  /// `MainWindowRoot` captures it here (in its launch-time `onAppear`) to give
  /// AppKit entry points — notably a Dock click with no open windows — a way to
  /// reopen a window once the user has closed them all.
  @ObservationIgnored var openWindowByID: (@MainActor (String) -> Void)?

  /// Brings the main window forward (showing the wizard or the ready screen).
  func openMainWindow() { openWindowByID?(MainWindow.id) }

  /// Surfaces the main window *and* makes the app frontmost. Shared by the menu
  /// bar's "Open Blurt", the missing-key hotkey nudge, and the permission-revoked
  /// kick-back: all need the app pulled in front of whatever the user was in.
  ///
  /// When the window already exists (the app is just running in the background,
  /// possibly minimized to the Dock), raise it directly: `openWindow(id:)` focuses
  /// the scene but won't deminiaturize a window the user sent to the Dock or
  /// reliably re-front an existing one. Only when no main window exists (the user
  /// closed it) do we recreate it via the scene. Returns the window it raised,
  /// or nil when it had to ask the scene to recreate one — the new NSWindow only
  /// materializes on a later run-loop pass.
  @discardableResult func surfaceMainWindow() -> NSWindow? {
    NSApp.activate()
    if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == MainWindow.id }) {
      main.deminiaturize(nil)
      main.makeKeyAndOrderFront(nil)
      return main
    }
    openMainWindow()
    return nil
  }

  /// True once the launch-time activation has run.
  @ObservationIgnored private var didActivateAtLaunch = false

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
  /// rights. `orderFrontRegardless()` additionally raises the window to the front
  /// of its level even while the app is inactive (it's the same call the overlay
  /// pill uses to surface without activating), as a defensive fallback for any
  /// launch path that doesn't grant those rights. Targets the one `canBecomeMain`
  /// window — the main scene — rather than the non-activating overlay panel.
  func activateAtLaunchIfNeeded() {
    guard !didActivateAtLaunch else { return }
    didActivateAtLaunch = true
    NSApp.activate()
    if let main = NSApp.windows.first(where: { $0.canBecomeMain }) {
      main.makeKeyAndOrderFront(nil)
      main.orderFrontRegardless()
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // No permission prompts fire at launch. Accessibility (and Microphone) are
    // requested only when the user taps the matching button in the setup
    // screen's permission rows — see `PermissionsStepView`.
    // Pressing the hotkey with no key saved brings the main window forward (and
    // activates the app, since the user is in another app when they press it) so
    // they can add a key via the wizard. `openWindowByID` is captured by the
    // main window's launch-time `onAppear` (the window is always presented at
    // launch), so it's set by the time the hotkey fires.
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
        // (the engine-owned `PersistedSettings` roster) back to their defaults. The API
        // key already uses an in-memory store, and window state is handled test-
        // side. Guarded by UITestMode (only the runner passes -BlurtUITest), so a
        // normal launch is untouched — running the UI tests locally does reset
        // these, by design.
        let defaults = UserDefaults.standard
        for key in PersistedSettings.allDefaultsKeys {
          defaults.removeObject(forKey: key)
        }
        coord = AppCoordinator(
          onMissingAPIKey: onMissingAPIKey,
          components: .uiTest(),
          apiKey: APIKeyModel(
            keyStore: InMemoryAPIKeyStore(),
            validateKey: { UITestKeyValidation.result(for: $0) }))
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
    self.wizardController = makeWizardController(coord: coord)

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

  /// Builds the setup wizard's controller. Created before the run loop presents
  /// any scene, so `MainWindowRoot` always finds it; on a configured launch its
  /// init reveals the overlay pill even though no window is shown, and
  /// `onNeedsForeground` fires when a configured app loses a requirement (e.g. a
  /// revoked permission) so the user is pulled back into onboarding even if every
  /// window was closed.
  private func makeWizardController(coord: AppCoordinator) -> WizardController {
    let onNeedsForeground: @MainActor () -> Void = { [weak self] in self?.surfaceMainWindow() }
    var checkPermissions: () -> PermissionStatus = { PermissionsChecker.check() }
    #if UITEST_HOOKS
      // Under the ready-state flag, force the fully-configured state so the main
      // window renders `ReadyView` instead of the wizard: save a key and inject an
      // all-granted permissions stub (the test host can't grant real TCC access).
      // Without the flag the wizard shows as usual, so wizard-based tests are
      // unaffected.
      if UITestMode.isReadyStateRequested {
        coord.apiKey.save(UITestIdentifiers.validAPIKey)
        checkPermissions = { PermissionStatus(microphone: true, accessibility: true) }
      }
    #endif
    return WizardController(
      coordinator: coord,
      onNeedsForeground: onNeedsForeground,
      checkPermissions: checkPermissions)
  }

  #if UITEST_HOOKS
    /// Runs several stubbed dictation cycles through the live coordinator so a
    /// Leaks-instrument recording exercises the full app-shell object graph. See
    /// the call site in `applicationDidFinishLaunching` and `scripts/leaks.sh`.
    private func runLeakExercise(_ coord: AppCoordinator) async {
      coord.apiKey.save(UITestIdentifiers.validAPIKey)  // clear the missing-key gate
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
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    NSApp.activate()
    if !flag { openMainWindow() }
    return true
  }
}
