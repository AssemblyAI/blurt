import SwiftUI

// Scene support for Blurt's two windows.
//
// Neither window is a hand-rolled `NSWindow`: both are SwiftUI scenes declared in
// `BlurtApp`. These types are the glue between those scenes and the long-lived
// models the app delegate owns.
//
// - Main window (`MainWindow`): the primary window, a `Window` scene opened via
//   `openWindow(id:)`. While the app isn't fully configured it shows the setup
//   wizard; once it is, it shows `ReadyView` (the shortcut readout).
// - Settings (`SettingsWindowRoot`): change the API key or dictation shortcut. A
//   `Settings` scene, so ⌘, comes wired for free; opened programmatically via the
//   `openSettings` environment action (the ready screen's buttons and the menu
//   bar item).

enum MainWindow {
  /// Scene identifier for `openWindow(id:)` / the `Window(id:)` scene.
  static let id = "main"

  /// Width of every window's content, and so — under
  /// `.windowResizability(.contentSize)` — of the windows themselves. Apple's
  /// common settings-pane width; height stays content-driven (`.fixedSize`), so a
  /// grouped `Form` hugs its content like a native pane instead of padding out to
  /// a hard-coded box.
  ///
  /// Shared rather than restated per view because the main window swaps
  /// `WizardView` ↔ `ReadyView` in place: if those two disagree, the window visibly
  /// jumps on the transition, and the `Color.clear` placeholders have to match them
  /// or the defensive branch resizes it.
  static let contentWidth: CGFloat = 480

  /// The main window's vertical rhythm, read off the design's own geometry (the
  /// "Blurt hub" comp, measured at 1×) rather than chosen: stacked sections and
  /// the wordmark-to-readout gap at 26, a caption to the card it names at 12,
  /// and 45 under the shortcut readout before the controls begin.
  ///
  /// Here rather than private to `ReadyView` because its content views own
  /// their own captions — `RecentDictationsSection` draws the "Recent" label
  /// above its card exactly as `ReadyView` draws the Style row's caption — so a
  /// number private to one of them left the two captions sitting at different
  /// distances from the thing they label.
  static let sectionGap: CGFloat = 26
  static let captionGap: CGFloat = 12
  static let readoutGap: CGFloat = 45
}

/// Root view of the main `Window` scene. It pulls the long-lived models off the
/// app delegate (created at launch, before any window appears) and routes between
/// the setup wizard (when the app isn't ready) and the ready screen (when it is).
struct MainWindowRoot: View {
  var appDelegate: AppDelegate
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    if let controller = appDelegate.wizardController, let coordinator = appDelegate.coordinator {
      Group {
        if controller.isReady {
          ReadyView(
            coordinator: coordinator,
            openSettings: { openSettings() },
            addStyle: {
              // The "+" deep-links: flag the Advanced pane (where styles are
              // edited) before opening, so the user lands on the Styles
              // section instead of General — see `SettingsWindowRoot`.
              appDelegate.settingsOpensOnAdvanced = true
              openSettings()
            })
        } else {
          WizardView(controller: controller, coordinator: coordinator)
        }
      }
      .onAppear {
        // Capture the open action so AppKit entry points (a Dock click with no
        // open windows, the missing-key hotkey nudge) can reopen the main
        // window. The main window is always presented at launch
        // (`.defaultLaunchBehavior(.presented)`), so this runs before any of
        // those paths can fire, and `openWindow(id:)` opens any Window scene
        // regardless of which scene's environment supplied the action.
        //
        // Capture the action alone, not `self`: `openWindow` is an `@Environment`
        // property wrapper, so a bare `openWindow(id:)` in an escaping closure reads
        // as `self.openWindow` and captures the whole view struct — including this
        // strong `appDelegate`, which owns the closure. That cycle would keep a copy
        // of the view's environment alive for the process lifetime, and neither gate
        // sees it (`leaks.sh` can't fault an `AppDelegate` reachable from a root, and
        // `MemoryLeakTests` covers only the engine).
        appDelegate.openWindowByID = { [openWindow] id in openWindow(id: id) }
        // Permission polling runs for the app's whole life (started in the
        // controller's init), so the window only needs to refresh once on
        // appear to reflect any change made while it was closed.
        controller.refreshPermissions()
        // Now that the window is actually on screen, pull the app frontmost —
        // see `activateAtLaunchIfNeeded`. Done here rather than at launch-finish
        // because the window doesn't exist yet then.
        appDelegate.activateAtLaunchIfNeeded()
      }
      // Tag the window so `surfaceMainWindow()` can find and raise this exact
      // window (the menu bar's "Open Blurt" needs to deminiaturize/front it when
      // the app is already running).
      .windowIdentifier(MainWindow.id)
    } else {
      // Defensive only: `applicationDidFinishLaunching` creates the models
      // before the run loop presents any scene, so this branch shouldn't show.
      Color.clear.frame(width: MainWindow.contentWidth, height: 320)
    }
  }
}
