import AppKit
import BlurtEngine
import SwiftUI

/// The menu bar status item's icon. Reads the live dictation status off the
/// coordinator (created after launch, so nil early on — idle until then) and
/// re-renders as the pipeline moves, since `AppCoordinator` is `@Observable`.
/// A Record-button recording — including one "Auto-record meetings" started
/// with the window closed — shows here too (#345), so capturing the mic and
/// Mac audio is never invisible.
/// The status enum, its phase mapping, and the glyph/VoiceOver strings all live
/// in BlurtEngine (`MenuBarStatus`), where `swift test` covers them — this view
/// just draws what the engine resolves, mirroring how `OverlayView` renders
/// `OverlayUIState`.
struct MenuBarLabel: View {
  let appDelegate: AppDelegate

  var body: some View {
    let coordinator = appDelegate.coordinator
    let transcripts = coordinator?.transcripts
    let status = (coordinator?.menuBarStatus ?? .idle)
      .showing(recordingAudio: (transcripts?.isRecording ?? false) && !(transcripts?.isPaused ?? false))
    Image(systemName: status.symbolName)
      .accessibilityLabel(status.accessibilityLabel)
  }
}

/// The menu shown when the status item is clicked. A *convenience* surface for
/// the Dock app — every item here is also reachable via the Dock icon, ⌘,, or
/// the app menu, so if the macOS notch hides the status item on a crowded menu
/// bar nothing is actually lost. Its main jobs are surfacing the (otherwise
/// invisible) dictation hotkey for discoverability and a one-click way back to
/// the window.
struct MenuBarContent: View {
  let appDelegate: AppDelegate
  @Environment(\.openSettings) private var openSettings

  // Observed (as the ready screen does) so the reminder line updates live when
  // the dictation key or its mode changes in Settings (`ObservedKeyBindings`).
  @ObservedKeyBindings private var bindings
  private var triggerKey: TriggerKey? { bindings.dictationKey }
  private var activation: TriggerActivation { bindings.activation }

  var body: some View {
    // A recording of the mic and Mac audio is on — possibly one a meeting
    // started with the window closed: say so, and offer the way out here.
    if let transcripts = appDelegate.coordinator?.transcripts, transcripts.isRecording {
      Text(transcripts.isPaused ? "Recording paused" : "Recording mic and Mac audio")
      Button("Stop Recording") { transcripts.stopRecording() }
      Divider()
    }

    // Disabled informational row: the dictation trigger is an invisible lone
    // modifier, so spell it out here as the menu bar's discoverability anchor.
    if let triggerKey {
      Text("\(activation.label) \(triggerKey.spokenName) to dictate and paste")
    } else {
      // A command, not a disabled instruction: nothing dictates, so the fix
      // is the one thing this row should offer.
      Button("Choose Dictation Key…") {
        NSApp.activate()
        openSettings()
      }
    }

    Divider()

    Button("Open Blurt") {
      // Reuse the shared path so this both surfaces the window and pulls the app
      // frontmost (the menu bar item can be clicked while another app is active).
      appDelegate.surfaceMainWindow()
    }
    Button("Settings…") {
      NSApp.activate()
      openSettings()
    }
    CheckForUpdatesButton(model: appDelegate.updaterModel, activatesApp: true)

    Divider()

    Button("Quit Blurt") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q", modifiers: .command)
  }
}
