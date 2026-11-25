import AppKit
import BlurtEngine
import SwiftUI

/// An entry's actions — the list's contextual menu, and VoiceOver's actions on
/// the row.
struct EntryActions: View {
  let entry: SavedTranscript
  let model: TranscriptsModel
  let delete: () -> Void

  var body: some View {
    // A recording kept without a transcript opens by transcribing
    // (`TranscriptsModel.open`), so the action says that, and it has no text
    // to copy yet.
    Button(entry.needsTranscription ? "Transcribe" : "Open") { model.open(entry) }
    if entry.hasAudio {
      Button(model.isPlaying(entry) ? "Stop" : "Play") { model.togglePlayback(entry) }
    }
    if !entry.needsTranscription {
      Button("Copy") { NSPasteboard.copyAnnounced(entry.text) }
    }
    // Gated on `hasAudio` and resolved on click: `audioURL` resolves a file's
    // bookmark, file-system work this menu is built too often to repeat.
    if entry.hasAudio {
      Button("Show in Finder") {
        if let url = entry.audioURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
    }
    Divider()
    Button("Delete…", role: .destructive, action: delete)
  }
}
