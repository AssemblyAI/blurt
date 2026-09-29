import AppKit
import SwiftUI

/// The "Check for Updates…" menu item, shared by the app menu (`BlurtCommands`)
/// and the menu-bar item. A `View` rather than a bare `Button` inside the
/// `Commands` body — the shape Sparkle's own SwiftUI guidance uses — because a
/// view is what reliably re-renders when the observed `canCheckForUpdates`
/// flips, which is what disables the item while a check runs (and in builds
/// that never start the updater).
struct CheckForUpdatesButton: View {
  let model: UpdaterModel
  /// Pull Blurt frontmost first, so Sparkle's window isn't opened behind the app
  /// the user was in. The menu-bar item needs it (it can be clicked while
  /// another app is active); the app menu is only reachable with Blurt active.
  var activatesApp = false

  var body: some View {
    Button("Check for Updates…") {
      if activatesApp { NSApp.activate() }
      model.checkForUpdates()
    }
    .disabled(!model.canCheckForUpdates)
  }
}
