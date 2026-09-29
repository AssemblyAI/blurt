import SwiftUI

/// App-menu commands. The standard ⌘, "Settings…" item is supplied by the
/// `Settings` scene itself (see `BlurtApp`).
struct BlurtCommands: Commands {
  var appDelegate: AppDelegate

  var body: some Commands {
    // "Check for Updates…" sits just below "About Blurt" in the app menu — the
    // conventional macOS spot, and the placement Sparkle's own SwiftUI guidance
    // uses (`CommandGroup(after: .appInfo)`). It drives the same Sparkle updater
    // as the Settings button (see `UpdaterModel`), and is disabled while a check
    // is already running or in builds that don't update. The ellipsis marks that
    // it goes off and does work (and may present a dialog).
    CommandGroup(after: .appInfo) {
      CheckForUpdatesButton(model: appDelegate.updaterModel)
    }
    // Blurt ships no help book, so SwiftUI's default "Blurt Help" item would
    // open nothing; it's replaced with the two outbound links that do belong
    // here — the issue tracker (also in the main window's footer) and the
    // share intent, which moved out of that footer so its quietest line stops
    // reading as an ad. No ellipses: they open a page and ask nothing more, the
    // way Apple's own Help-menu links read. Each omits itself if its URL fails
    // to build.
    CommandGroup(replacing: .help) {
      if let url = BlurtLinks.reportBug {
        Link("Report a Bug", destination: url)
      }
      if let url = BlurtLinks.shareOnLinkedIn {
        Link("Share Blurt on LinkedIn", destination: url)
      }
    }
  }
}
