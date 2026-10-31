#if UITEST_HOOKS

  import AssemblyAI
  import BlurtEngine
  import Foundation

  // UI-test doubles for the transcription half of the app: a canned network
  // transport standing in for the async API and the LLM Gateway, a seeded
  // history, and a sample file to transcribe. Same gate as the rest of the
  // hooks (`UITEST_HOOKS`), so none of it ships.

  /// Answers the async API and the gateway with fixed results, offline: any
  /// file transcribes to a two-speaker exchange, a title request returns
  /// `cannedFileTitle`, and any other task returns `cannedTaskResult`.
  nonisolated struct UITestTranscriptTransport: HTTPTransport {
    // Handed in on the main actor at creation (`uiTest(store:)`): the app
    // target's constants are main-actor, and this answers off it.
    let speakerA: String
    let speakerB: String
    let title: String
    let taskResult: String

    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
      let path = request.url?.path ?? ""
      let body: Any =
        switch path {
        case "/v2/upload": ["upload_url": "https://uitest.invalid/audio"]
        case "/v2/transcript": ["id": "uitest", "status": "queued"]
        case let path where path.hasPrefix("/v2/transcript/"):
          [
            "id": "uitest", "status": "completed",
            "text": "\(speakerA) \(speakerB)",
            "utterances": [["speaker": "A", "text": speakerA], ["speaker": "B", "text": speakerB]],
          ]
        default:
          // The gateway: a title request says so in its instruction.
          [
            "choices": [
              [
                "message": [
                  "content": Self.isTitleRequest(request) ? title : taskResult
                ],
                "finish_reason": "stop",
              ]
            ]
          ]
        }
      let data = try JSONSerialization.data(withJSONObject: body)
      let response = HTTPURLResponse(
        url: request.url ?? URL(filePath: "/"), statusCode: 200, httpVersion: nil, headerFields: nil)
      return (data, response ?? URLResponse())
    }

    nonisolated func upload(
      for request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
      delegate: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, URLResponse) {
      throw URLError(.unsupportedURL)
    }

    nonisolated private static func isTitleRequest(_ request: URLRequest) -> Bool {
      guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return false }
      return text.contains("short, specific title")
    }
  }

  extension TranscriptsModel {
    /// The model over `store`, with the canned transport behind both the
    /// async API and the gateway.
    static func uiTest(store: TranscriptStore) -> TranscriptsModel {
      let transport = UITestTranscriptTransport(
        speakerA: UITestIdentifiers.cannedFileSpeakerA, speakerB: UITestIdentifiers.cannedFileSpeakerB,
        title: UITestIdentifiers.cannedFileTitle, taskResult: UITestIdentifiers.cannedTaskResult)
      let key = UITestIdentifiers.validAPIKey
      return TranscriptsModel(
        transcriber: FileTranscriber(
          client: AsyncTranscriptionClient(transport: transport, pollInterval: .zero), apiKeyProvider: { key }),
        llm: TranscriptLLM(apiKeyProvider: { key }, transport: transport),
        store: store)
    }
  }

  /// The known history a seeded launch starts with, newest first.
  enum UITestHistorySeed {
    static func seed(_ store: TranscriptStore) {
      let now = Date.now
      let entries = [
        SavedTranscript(
          kind: .recording, date: now.addingTimeInterval(-60),
          text:
            "Speaker A: \(UITestIdentifiers.seededRecordingSpeakerA)\n\nSpeaker B: \(UITestIdentifiers.seededRecordingSpeakerB)",
          fileURL: sampleFile(),
          plainText: "\(UITestIdentifiers.seededRecordingSpeakerA) \(UITestIdentifiers.seededRecordingSpeakerB)",
          generatedTitle: UITestIdentifiers.seededRecordingTitle),
        SavedTranscript(
          kind: .dictation, date: now.addingTimeInterval(-120), text: UITestIdentifiers.seededDictationText),
        SavedTranscript(
          kind: .readAloud, date: now.addingTimeInterval(-180), text: UITestIdentifiers.seededReadText,
          fileURL: sampleFile()),
      ]
      try? store.save(entries)
    }

    /// A small file to stand for audio: the canned transport never reads it.
    static func sampleFile() -> URL {
      let url = FileManager.default.temporaryDirectory.appending(path: "blurt-uitest-sample.m4a")
      if !FileManager.default.fileExists(atPath: url.path) { try? Data("uitest".utf8).write(to: url) }
      return url
    }
  }

#endif
