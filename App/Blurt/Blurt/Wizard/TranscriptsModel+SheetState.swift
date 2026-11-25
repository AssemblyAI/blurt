// What the sheet shows and who holds it, read off the model's state, and
// closing it — split from TranscriptsModel.swift for the file-length budget.
extension TranscriptsModel {
  /// The chips the open entry offers: Plain text only where it differs from
  /// the labelled transcript — a file or recording with several speakers.
  var availableFacets: [TranscriptFacet] {
    TranscriptFacet.allCases.filter { $0 != .plain || openEntry?.plainText != nil }
  }

  /// What the selected facet shows, when it has text — what Copy copies.
  var selectedText: String? {
    guard case .ready(let text) = contents[selection] else {
      return nil
    }
    return text
  }

  var isPaused: Bool { pausedAt != nil }

  var isRecording: Bool {
    if case .recording = state { true } else { false }
  }

  /// Whether Record can start: not while anything else has the sheet.
  var canRecord: Bool { state == .idle }

  /// Closes the sheet. A transcription still uploading or running is
  /// abandoned; transforms already fetched are saved.
  ///
  /// The transcript itself stays: the sheet still draws it as it animates
  /// out, and emptied now it would shrink to a blank panel on the way.
  /// Whatever opens the sheet next resets first.
  ///
  /// Never while recording or finishing one: a stray Esc must not cost a
  /// meeting. Stop or Discard are the only ways out of a recording.
  func dismiss() {
    guard !isRecordingBusy else {
      return
    }
    reset(keepingTranscript: true)
    state = .idle
  }
}
