import SwiftUI

/// App-menu commands. The standard ⌘, "Settings…" item is supplied by the
/// `Settings` scene itself (see `BlurtApp`), so nothing to add here.
struct BlurtCommands: Commands {
  var body: some Commands {
    // Updates are checked on demand from Settings (see `UpdateStepView`), so
    // there is no "Check for Updates…" command in the app menu.
    // Blurt ships no help book, so SwiftUI's default Help menu would show a
    // dead "Blurt Help" item that opens nothing. Remove it rather than leave
    // a control that does nothing.
    CommandGroup(replacing: .help) {}
  }
}
