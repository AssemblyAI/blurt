import Foundation
import UniformTypeIdentifiers

// The model's file-type rules, and the refusal of a file that
// breaks them, split from TranscriptsModel.swift for the file-length budget.
extension TranscriptsModel {
  /// Whether a URL is worth trying: a file whose type is audio or video. The
  /// service is the real judge — this only keeps a folder or document from
  /// opening the sheet just to fail.
  static func accepts(_ url: URL) -> Bool {
    guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else {
      return false
    }
    return type.conforms(to: .audiovisualContent)
  }

  /// Transcribes the first audio or video file among `urls` — dropped on the
  /// window or the Dock icon, or opened from Finder's Open With — or says why
  /// none was. Never over a recording: it owns the sheet until it's saved.
  func openFiles(_ urls: [URL]) {
    guard !isRecordingBusy else {
      return
    }
    guard let url = urls.first(where: Self.accepts) else {
      refuse(urls.first)
      return
    }
    transcribe(url)
  }

  /// Shows why files that held no audio or video weren't transcribed.
  private func refuse(_ url: URL?) {
    reset()
    state = .failed(
      fileName: url?.lastPathComponent ?? "Dropped item",
      message: "Blurt can only transcribe audio and video files."
    )
  }
}
