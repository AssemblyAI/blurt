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
    // Welcome-window chrome: the wizard and ready screen are splash-style
    // surfaces, not document/preferences windows — hide the titlebar (keeping
    // the traffic lights) and let the window drag from its body, since there's
    // no longer a visible bar to grab.
    .windowStyle(.hiddenTitleBar)
    .windowBackgroundDragBehavior(.enabled)
    // Always present the main window at launch — both first-run onboarding and a
    // configured launch (the "ready" screen) come up front, rather than the app
    // launching silently to just the overlay pill. (`AppDelegate` activates the
    // app so it's frontmost; the Dock/⌘, reopen it once closed.)
    .defaultLaunchBehavior(.presented)
    .commands {
      BlurtCommands()
    }

    // Settings scene: change the API key or dictation shortcut. SwiftUI wires
    // the standard ⌘, "Settings…" menu item to this scene automatically; it's
    // opened on demand (⌘, / the ready screen's link / the menu bar item, via
    // `openSettings`), never at launch. Keeps standard window chrome.
    Settings {
      SettingsWindowRoot(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)

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
      // Pin the harness to the top-leading corner so it never overlaps the
      // centered main window: the two stay simultaneously interactable, so a test
      // can drive a dictation on the harness and read the result on the ready
      // screen without closing/reopening either (XCUITest can't click a control
      // under another window). Test-only (UITEST_HOOKS).
      .defaultPosition(.topLeading)
    #endif
  }
}
