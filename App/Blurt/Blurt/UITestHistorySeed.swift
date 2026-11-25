#if UITEST_HOOKS

  import BlurtEngine
  import Foundation

  /// The known history a seeded launch starts with, newest first.
  enum UITestHistorySeed {
    static func seed(_ store: TranscriptStore) {
      let now = Date.now
      let entries = [
        SavedTranscript(
          kind: .recording,
          date: now.addingTimeInterval(-60),
          text:
            "Speaker A: \(UITestIdentifiers.seededRecordingSpeakerA)\n\nSpeaker B: \(UITestIdentifiers.seededRecordingSpeakerB)",
          fileURL: sampleFile(),
          plainText: "\(UITestIdentifiers.seededRecordingSpeakerA) \(UITestIdentifiers.seededRecordingSpeakerB)",
          generatedTitle: UITestIdentifiers.seededRecordingTitle
        ),
        SavedTranscript(
          kind: .dictation, date: now.addingTimeInterval(-120), text: UITestIdentifiers.seededDictationText
        ),
        SavedTranscript(
          kind: .readAloud,
          date: now.addingTimeInterval(-180),
          text: UITestIdentifiers.seededReadText,
          fileURL: sampleFile()
        ),
      ]
      try? store.save(entries)
    }

    /// A small file to stand for audio: the canned transport never reads it.
    static func sampleFile() -> URL {
      let url = FileManager.default.temporaryDirectory.appending(path: "blurt-uitest-sample.m4a")
      if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
        try? Data("uitest".utf8).write(to: url)
      }
      return url
    }
  }

#endif
