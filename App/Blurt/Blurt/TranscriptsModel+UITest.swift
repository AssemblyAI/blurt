#if UITEST_HOOKS

  import AssemblyAI
  import BlurtAssemblyAI
  import BlurtEngine

  extension TranscriptsModel {
    /// The model over `store`, with the canned transport behind both the
    /// async API and the gateway.
    static func uiTest(store: TranscriptStore) -> TranscriptsModel {
      let transport = UITestTranscriptTransport(
        speakerA: UITestIdentifiers.cannedFileSpeakerA,
        speakerB: UITestIdentifiers.cannedFileSpeakerB,
        title: UITestIdentifiers.cannedFileTitle,
        taskResult: UITestIdentifiers.cannedTaskResult
      )
      let key = UITestIdentifiers.validAPIKey
      return TranscriptsModel(
        apiKey: { key },
        transcriber: FileTranscriber(client: AsyncTranscriptionClient(transport: transport, pollInterval: .zero)) {
          key
        },
        llm: TranscriptLLM(apiKeyProvider: { key }, transport: transport),
        store: store
      )
    }
  }

#endif
