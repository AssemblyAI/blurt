#if UITEST_HOOKS

  import AssemblyAI
  import BlurtEngine
  import Foundation

  // UI-test doubles for the transcription half of the app: a canned network
  // transport standing in for the async API and the LLM Gateway, a seeded
  // history (`UITestHistorySeed`), and a sample file to transcribe. Same gate
  // as the rest of the hooks (`UITEST_HOOKS`), so none of it ships.

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

    nonisolated private static func isTitleRequest(_ request: URLRequest) -> Bool {
      guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else {
        return false
      }
      return text.contains("short, specific title")
    }

    nonisolated func data(for request: URLRequest) throws -> (Data, URLResponse) {
      let path = request.url?.path ?? ""
      let body: Any =
        switch path {
        case "/v2/upload":
          ["upload_url": "https://uitest.invalid/audio"]

        case "/v2/transcript":
          ["id": "uitest", "status": "queued"]

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
        url: request.url ?? URL(filePath: "/"), statusCode: 200, httpVersion: nil, headerFields: nil
      )
      return (data, response ?? URLResponse())
    }

    nonisolated func upload(
      for _: URLRequest,
      streaming _: AsyncThrowingStream<Data, any Error>,
      delegate _: (any URLSessionTaskDelegate)?
    ) throws -> (Data, URLResponse) {
      throw URLError(.unsupportedURL)
    }
  }

#endif
