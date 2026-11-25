import SwiftUI

/// Root view of the main `Window` scene. It pulls the long-lived models off the
/// app delegate (created at launch, before any window appears) and routes between
/// the setup wizard (when the app isn't ready) and the ready screen (when it is).
struct MainWindowRoot: View {
  var appDelegate: AppDelegate
  @Environment(\.openWindow)
  private var openWindow

  var body: some View {
    if let controller = appDelegate.wizardController, let coordinator = appDelegate.coordinator {
      Group {
        if controller.isReady {
          ReadyView(coordinator: coordinator)
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
        let openWindowAction = openWindow
        appDelegate.openWindowByID = { [openWindowAction] id in openWindowAction(id: id) }
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
