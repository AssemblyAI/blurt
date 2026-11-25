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
