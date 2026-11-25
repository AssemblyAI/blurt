#if UITEST_HOOKS

  import AssemblyAI
  import BlurtEngine
  import Foundation

  extension TranscriptsModel {
    /// The model over `store`, with the canned transport behind both the
    /// async API and the gateway, and Record's doubles (`UITestRecordingCapture`,
    /// `UITestLiveSession`) behind its capture and live transcription, writing
    /// to a throwaway folder — never the user's Recordings.
    static func uiTest(store: TranscriptStore) -> TranscriptsModel {
      let transport = UITestTranscriptTransport(
        speakerA: UITestIdentifiers.cannedFileSpeakerA,
        speakerB: UITestIdentifiers.cannedFileSpeakerB,
        title: UITestIdentifiers.cannedFileTitle,
        taskResult: UITestIdentifiers.cannedTaskResult
      )
      // Speaker A's partial, then its final; then speaker B's.
      let script = [
        RealtimeTurn(order: 0, transcript: UITestIdentifiers.livePartialA, isFinal: false, speaker: "A"),
        RealtimeTurn(order: 0, transcript: UITestIdentifiers.liveFinalA, isFinal: true, speaker: "A"),
        RealtimeTurn(order: 1, transcript: UITestIdentifiers.livePartialB, isFinal: false, speaker: "B"),
        RealtimeTurn(order: 1, transcript: UITestIdentifiers.liveFinalB, isFinal: true, speaker: "B"),
      ]
      let key = UITestIdentifiers.validAPIKey
      return TranscriptsModel(
        apiKey: { key },
        transcriber: FileTranscriber(client: AsyncTranscriptionClient(transport: transport, pollInterval: .zero)) {
          key
        },
        llm: TranscriptLLM(apiKeyProvider: { key }, transport: transport),
        store: store,
        recorder: UITestRecordingCapture(),
        liveSession: { _ in UITestLiveSession.begin(script: script) },
        recordingsDirectory: FileManager.default.temporaryDirectory.appending(
          path: "blurt-uitest-recordings-\(UUID().uuidString)",
          directoryHint: .isDirectory
        )
      )
    }
  }

#endif
