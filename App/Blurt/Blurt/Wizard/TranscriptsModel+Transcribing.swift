import AssemblyAI
import BlurtAssemblyAI
import BlurtEngine
import Foundation

extension TranscriptsModel {
  /// Uploads and transcribes `url`, saving the result and opening it.
  ///
  /// `entry` is a recording saved without a transcript (`keepUntranscribed`):
  /// the transcript fills it in; finding nothing deletes it, file and all;
  /// failing keeps it for Try Again — its audio may hold a whole meeting.
  ///
  /// Never over a recording: a file dropped while one runs is refused, or the
  /// recording would be left capturing with no sheet to stop it.
  func transcribe(_ url: URL, entry: SavedTranscript? = nil) {
    guard !isRecordingBusy else {
      return
    }
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
              guard let self, self.currentRun == run, case .transcribing = self.state else {
                return
              }
              self.state = .transcribing(fileName: fileName, phase: phase)
            }
          }
        )
      } catch {
        outcome = .failure(error)
      }
      guard !Task.isCancelled, let self else {
        return
      }
      finish(outcome, fileName: fileName, url: url, entry: entry)
    }
  }

  /// Saves, fills in or reports what a transcription run came back with.
  private func finish(
    _ outcome: Result<FileTranscription, any Error>,
    fileName: String,
    url: URL,
    entry: SavedTranscript?
  ) {
    switch outcome {
    case .success(let result) where result.text.trimmedNonEmpty() == nil:
      if let entry { delete(entry) }
      state = .failed(fileName: fileName, message: "No speech was found in that file.")

    case .success(let result):
      guard let entry else {
        add(SavedTranscript(kind: .file, date: .now, text: result.text, fileURL: url, plainText: result.plainText))
        return
      }
      if !fillIn(entry, with: result) { state = .idle }

    case .failure(let error):
      // A failure isn't "no speech": a recording's entry stays, untranscribed,
      // rather than costing the user the audio over a network blip.
      state = .failed(fileName: fileName, message: error.localizedDescription, retry: entry)
    }
  }
}
