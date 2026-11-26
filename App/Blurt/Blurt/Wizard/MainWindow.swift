import CoreFoundation

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
//   `Settings` scene, so ⌘, comes wired for free; opened from the ready screen
//   through `SettingsLink` and from the menu bar item through the
//   `openSettings` environment action.

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
}
