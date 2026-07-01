import SwiftUI

@main
struct BlurtApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {
    // Primary window: the setup wizard until the app is fully configured, then
    // the "ready" screen (see `MainWindowRoot`).
    Window("Blurt", id: MainWindow.id) {
      MainWindowRoot(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)
    // Always present the main window at launch — both first-run onboarding and a
    // configured launch (the "ready" screen) come up front, rather than the app
    // launching silently to just the overlay pill. (`AppDelegate` activates the
    // app so it's frontmost; the Dock/⌘, reopen it once closed.)
    .defaultLaunchBehavior(.presented)
    .commands {
      BlurtCommands(appDelegate: appDelegate)
    }

    // Settings window: change the API key or dictation shortcut. Opened on
    // demand (⌘, / the ready screen's link), never at launch.
    Window("Blurt Settings", id: SettingsWindow.id) {
      SettingsWindowRoot(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)

    // Menu bar status item: a live dictation indicator (idle / recording /
    // transcribing) plus a discoverability menu for the otherwise-invisible
    // hotkey. Layered *on top of* the Dock icon — it's bonus convenience, not a
    // replacement, so we keep no `LSUIElement`. (A menu-bar-only variant was
    // reverted twice because the macOS notch can hide the item; here the Dock
    // icon remains the guaranteed entry point, so that hiding only degrades the
    // convenience rather than locking the user out.)
    MenuBarExtra {
      MenuBarContent(appDelegate: appDelegate)
    } label: {
      MenuBarLabel(appDelegate: appDelegate)
    }

    #if UITEST_HOOKS
      // XCUITest harness window. Compiled when the `UITEST_HOOKS` condition is on
      // (the Debug default; stripped by scripts/dev-build.sh) but only presented
      // and populated when launched with `-BlurtUITest`, so a normal run never
      // sees it. See `UITestSupport.swift`.
      Window("Blurt UI Test Harness", id: UITestID.harnessWindow) {
        if UITestMode.isActive {
          UITestHarnessView(appDelegate: appDelegate)
        }
      }
      .windowResizability(.contentSize)
      .defaultLaunchBehavior(UITestMode.isActive ? .presented : .suppressed)
    #endif
  }
}
