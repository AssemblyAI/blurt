import BlurtEngine
import Foundation
import SwiftUI

@main
struct BlurtApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  /// Tell the engine which app it is running inside — the Keychain item, the
  /// logging subsystem, the `UserDefaults` prefix, the log directory, the product
  /// name in update alerts, and the release feed the update check reads.
  ///
  /// This is the composition root: the identity belongs to the host, and a fork
  /// or a second embedder replaces exactly these lines rather than hunting
  /// constants through the engine. Earliest hook a SwiftUI `App` has, which is
  /// what `HostIdentity.configure(_:)` asks for.
  ///
  /// **Which** identity depends on which app this is. Debug builds ship as
  /// `dev.alex.blurt.dev` / "Blurt Dev" (see `project.yml`), which macOS already
  /// treats as a separate app — its own TCC rows, its own defaults domain — but
  /// *not* its own Keychain item, since Keychain items are per login keychain
  /// rather than per app. Shared, a dev build read the shipping app's API key,
  /// could overwrite it, and could delete it outright through Settings → Reset.
  /// `.blurtDev` differs from `.blurt` in exactly that one field.
  ///
  /// Decided from the **running bundle id** rather than `#if DEBUG`: the id is
  /// what actually makes these two apps to macOS, and it follows
  /// `PRODUCT_BUNDLE_IDENTIFIER`, so a configuration added later gets the dev
  /// identity by default (the same reasoning that made the debug id the default
  /// in `project.yml`) instead of silently reaching for the shipping key because
  /// someone forgot a compilation condition. `HostIdentity.blurt.subsystem` is
  /// the shipping id — the one place that string is written down.
  init() {
    let isShippingBuild = Bundle.main.bundleIdentifier == HostIdentity.blurt.subsystem
    HostIdentity.configure(isShippingBuild ? .blurt : .blurtDev)
  }

  var body: some Scene {
    // Primary window: the setup wizard until the app is fully configured, then
    // the "ready" screen (see `MainWindowRoot`).
    Window(UITestIdentifiers.mainWindowTitle, id: MainWindow.id) {
      MainWindowRoot(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)
    // Standard window chrome: the titlebar names the app ("Blurt") and gives
    // the window its drag handle, so no hidden-titlebar splash treatment and no
    // body-drag behaviour (which only earned its place while there was no bar
    // to grab).
    // Always present the main window at launch — both first-run onboarding and a
    // configured launch (the "ready" screen) come up front, rather than the app
    // launching silently to just the overlay pill. (`AppDelegate` activates the
    // app so it's frontmost; the Dock/⌘, reopen it once closed.)
    .defaultLaunchBehavior(.presented)
    .commands {
      BlurtCommands(appDelegate: appDelegate)
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
      Window(UITestIdentifiers.harnessWindowTitle, id: UITestIdentifiers.harnessWindowID) {
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
