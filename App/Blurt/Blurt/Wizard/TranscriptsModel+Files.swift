import BlurtEngine
import Foundation
import UniformTypeIdentifiers

// The model's transcription of a file or recording, its file naming and
// file-type rules, and the refusal of a file that breaks them, split from
// TranscriptsModel.swift for the file-length budget.
extension TranscriptsModel {
  /// Transcribes the first audio or video file among `urls` — dropped on the
  /// window or the Dock icon, or opened from Finder's Open With — or says why
  /// none was. Never over a recording: it owns the sheet until it's saved.
  func openFiles(_ urls: [URL]) {
    guard !isRecordingBusy else { return }
    guard let url = urls.first(where: Self.accepts) else {
      refuse(urls.first)
      return
    }
    transcribe(url)
  }

  /// Whether a URL is worth trying: a file whose type is audio or video. The
  /// service is the real judge — this only keeps a folder or document from
  /// opening the sheet just to fail.
  static func accepts(_ url: URL) -> Bool {
    guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return type.conforms(to: .audiovisualContent)
  }

  /// Shows why files that held no audio or video weren't transcribed.
  private func refuse(_ url: URL?) {
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

  // MARK: - Transcribing

  /// Uploads and transcribes `url`, saving the result and opening it.
  ///
  /// `kind` is `.recording` for a recording whose live transcript came back
  /// empty: its audio is still worth the async pass, and if that finds nothing
  /// either the file is deleted rather than left with no entry pointing at it.
  /// If the pass fails, the recording is saved untranscribed
  /// (`SavedTranscript.isUntranscribed`): the audio may hold the whole meeting,
  /// and the entry keeps it in the Library to transcribe once the network is
  /// back, rather than orphaned in its folder.
  ///
  /// Never over a recording: a file dropped while one runs is refused, or the
  /// recording would be left capturing with no sheet to stop it.
  func transcribe(_ url: URL, kind: SavedTranscript.Kind = .file) {
    startTranscription(of: url, kind: kind, entryID: nil)
  }

  /// Transcribes a recording saved untranscribed, filling in its entry.
  func transcribe(_ entry: SavedTranscript) {
    guard entry.isUntranscribed, let url = entry.fileURL else { return }
    startTranscription(of: url, kind: .recording, entryID: entry.id)
  }

  /// The failure page's Try Again: the untranscribed recording `id`, again.
  func retryRecording(_ id: SavedTranscript.ID) {
    guard let entry = history.first(where: { $0.id == id }) else { return }
    transcribe(entry)
  }

  /// `entryID` is the untranscribed entry this run fills in, if it's one.
  private func startTranscription(of url: URL, kind: SavedTranscript.Kind, entryID: SavedTranscript.ID?) {
    guard !isRecordingBusy else { return }
    reset()
    let fileName = url.lastPathComponent
    let run = UUID()
    currentRun = run
    state = .transcribing(fileName: fileName, phase: .uploading)
    tasks[.full] = Task { [weak self, transcriber] in
      let outcome: Result<FileTranscription, any Error>
      do {
        outcome = .success(
          try await transcriber.transcribe(fileAt: url) { phase in
            Task { @MainActor in
              guard let self, self.currentRun == run, case .transcribing = self.state else { return }
              self.state = .transcribing(fileName: fileName, phase: phase)
            }
          })
      } catch {
        outcome = .failure(error)
      }
      guard !Task.isCancelled, let self else { return }
      switch outcome {
      case .success(let result) where result.text.trimmedNonEmpty() == nil:
        if kind == .recording {
          if let entryID { removeEntry(entryID) }
          try? FileManager.default.removeItem(at: url)
        }
        state = .failed(fileName: fileName, message: "No speech was found in that file.")
      case .success(let result):
        if let entryID, let index = history.firstIndex(where: { $0.id == entryID }) {
          history[index].replaceTranscript(result.text, plain: result.plainText)
          save()
          let entry = history[index]
          open(entry)
          Task { [weak self] in await self?.applyTitle(to: entry) }
        } else if entryID == nil || FileManager.default.fileExists(atPath: url.path) {
          add(SavedTranscript(kind: kind, date: .now, text: result.text, fileURL: url, plainText: result.plainText))
        } else {
          // Deleted, audio and all, while it was transcribing.
          state = .idle
        }
      case .failure(let error):
        // A failure isn't "no speech": the recording is kept, with an entry
        // that points at it, rather than costing the user the audio over a
        // network blip.
        var recording: SavedTranscript.ID?
        if kind == .recording { recording = entryID ?? keepUntranscribed(url) }
        state = .failed(fileName: fileName, message: error.localizedDescription, recording: recording)
      }
    }
  }

  /// Saves the recording at `url` with no transcript yet, so the Library
  /// keeps it; returns its entry's id.
  private func keepUntranscribed(_ url: URL) -> SavedTranscript.ID {
    let entry = SavedTranscript(kind: .recording, date: .now, text: "", fileURL: url)
    history.insert(entry, at: 0)
    save()
    return entry.id
  }

  /// Drops an entry from the history, leaving its audio to the caller.
  private func removeEntry(_ id: SavedTranscript.ID) {
    history.removeAll { $0.id == id }
    save()
  }
}
