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
//   `openSettings` environment action (the ready screen's link and menu bar item).

enum MainWindow {
  /// Scene identifier for `openWindow(id:)` / the `Window(id:)` scene.
  static let id = "main"
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
          ReadyView(coordinator: coordinator, openSettings: { openSettings() })
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
        appDelegate.openWindowByID = { openWindow(id: $0) }
        // Permission polling runs for the app's whole life (started in the
        // controller's init), so the window only needs to refresh once on
        // appear to reflect any change made while it was closed.
        controller.refreshPermissions()
        // Now that the window is actually on screen, pull the app frontmost —
        // see `activateAtLaunchIfNeeded`. Done here rather than at launch-finish
        // because the window doesn't exist yet then.
        appDelegate.activateAtLaunchIfNeeded()
      }
      // The splash-style titlebar treatment lives on the scene — see
      // `.windowStyle(.hiddenTitleBar)` / `.windowBackgroundDragBehavior` in
      // `BlurtApp`.
      // Tag the window so `surfaceMainWindow()` can find and raise this exact
      // window (the menu bar's "Open Blurt" needs to deminiaturize/front it when
      // the app is already running).
      .windowIdentifier(MainWindow.id)
    } else {
      // Defensive only: `applicationDidFinishLaunching` creates the models
      // before the run loop presents any scene, so this branch shouldn't show.
      Color.clear.frame(width: 480, height: 320)
    }
  }
}
