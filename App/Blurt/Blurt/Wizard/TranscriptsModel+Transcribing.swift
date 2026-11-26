import AssemblyAI
import BlurtAssemblyAI
import BlurtEngine
import Foundation

extension TranscriptsModel {
  /// Uploads and transcribes `url`, saving the result and opening it.
  ///
  /// `entry` is a recording saved without a transcript (`keepUntranscribed`):
  /// the transcript fills it in; finding nothing or failing keeps it for Try
  /// Again — its audio may hold a whole meeting.
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
    // Try Again only for an entry still in the Library: one deleted while the
    // run was out can't be retried, and the page mustn't say it was saved.
    let retry = entry.flatMap { kept in history.contains { $0.id == kept.id } ? kept : nil }
    switch outcome {
    case .success(let result) where result.text.trimmedNonEmpty() == nil:
      // A recording's entry stays, untranscribed: quiet audio, or a language
      // the service didn't detect, is no reason to delete the user's audio.
      // Deleting it is theirs to do, from the Library.
      let what = entry == nil ? "file" : "recording"
      state = .failed(fileName: fileName, message: "No speech was found in that \(what).", retry: retry)

    case .success(let result):
      guard let entry else {
        add(SavedTranscript(kind: .file, date: .now, text: result.text, fileURL: url, plainText: result.plainText))
        return
      }
      if !fillIn(entry, with: result) { state = .idle }

    case .failure(let error):
      // A failure isn't "no speech": a recording's entry stays, untranscribed,
      // rather than costing the user the audio over a network blip.
      state = .failed(fileName: fileName, message: error.localizedDescription, retry: retry)
    }
  }
}
