import BlurtEngine
import Foundation
import UniformTypeIdentifiers

// The model's file naming and file-type rules, and the refusal of a drop that
// breaks them, split from TranscriptsModel.swift for the file-length budget.
extension TranscriptsModel {
  /// Whether a dropped URL is worth trying: a file whose type is audio or
  /// video. The service is the real judge — this only keeps a dropped folder
  /// or document from opening the sheet just to fail.
  static func accepts(_ url: URL) -> Bool {
    guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .audiovisualContent)
  }

  /// Shows why a drop that held no audio or video file wasn't transcribed.
  func refuse(_ url: URL?) {
    guard !isRecordingBusy else { return }
    reset()
    state = .failed(
      fileName: url?.lastPathComponent ?? "Dropped item",
      message: "Blurt can only transcribe audio and video files.")
  }

  /// "Recording 2026-10-30 at 10.04.08.m4a" — the shape macOS names a
  /// screenshot, so recordings sort by time and read like the system's own.
  static func recordingName(at date: Date) -> String {
    "Recording \(TranscriptStore.fileStamp(date)).m4a"
  }
}
