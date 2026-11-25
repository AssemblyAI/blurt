import AppKit
import BlurtEngine
import SwiftUI

/// A recording whose transcription failed: it's kept in the Library, and
/// here it can be tried again or found in Finder.
struct RetryRecording: View {
  let entry: SavedTranscript
  let model: TranscriptsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("The recording is saved in your Library, so you can try again later.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Try Again") { model.retranscribe(entry) }
        if let url = entry.audioURL {
          Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .disabled(!FileManager.default.fileExists(atPath: url.path))
        }
      }
    }
  }
}
