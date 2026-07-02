import SwiftUI

/// App-menu commands. The standard ⌘, "Settings…" item is supplied by the
/// `Settings` scene itself (see `BlurtApp`), so nothing to add here.
struct BlurtCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    // Updates are silent and automatic (checked at launch, installed without a
    // prompt — see `AutoUpdater`), so there is no "Check for Updates…" command.
    // Blurt ships no help book, so SwiftUI's default Help menu would show a
    // dead "Blurt Help" item that opens nothing. Remove it rather than leave
    // a control that does nothing.
    CommandGroup(replacing: .help) {}

    // Developer aid: reveal the last prompt sent to AssemblyAI. Lives in the
    // Window menu (rather than a hotkey) so it's discoverable and can't collide
    // with the dictation trigger. The window scene is `.suppressed` at launch,
    // so this is the only way it opens; reselecting just re-focuses it.
    CommandGroup(after: .windowList) {
      Button("Prompt Inspector") {
        openWindow(id: PromptInspectorWindow.id)
      }
    }
  }
}
