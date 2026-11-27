import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

/// File transcription: the async API's upload → submit → poll flow, how
/// speaker turns are written out, the gateway transforms, and the saved history.
@Suite("File transcription")
struct FileTranscriptionTests {
  private func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  // MARK: - Async API

  @Test("uploads the raw file, submits it with speaker labels, polls until completed")
  func asyncFlow() async throws {
    let polls = Mutex(0)
    let submitted = Mutex(Data())
    let transport = FakeHTTPTransport { request in
      let path = request.url?.path ?? ""
      #expect(request.value(forHTTPHeaderField: "Authorization") == "key")
      switch (request.httpMethod, path) {
      case ("POST", "/v2/upload"):
        #expect(request.httpBody == Data("audio bytes".utf8))
        return (200, json(["upload_url": "https://cdn.example/abc"]))

      case ("POST", "/v2/transcript"):
        submitted.withLock { $0 = request.httpBody ?? Data() }
        return (200, json(["id": "t1", "status": "queued"]))

      case ("GET", "/v2/transcript/t1"):
        let count = polls.withLock { polled in
          polled += 1
          return polled
        }
        return count < 2
          ? (200, json(["id": "t1", "status": "processing"]))
          : (200, json(["id": "t1", "status": "completed", "text": "Hello there."]))

      default:
        Issue.record("unexpected request \(request.httpMethod ?? "") \(path)")
        return (500, Data())
      }
    }
    let client = AsyncTranscriptionClient(transport: transport, pollInterval: .zero)
    let phases = Mutex<[AsyncTranscriptionClient.Phase]>([])
    let transcript = try await withScratchAudioFile { url in
      try await client.transcribe(fileAt: url, apiKey: "key") { phase in
        phases.withLock { $0.append(phase) }
      }
    }
    #expect(transcript.text == "Hello there.")
    #expect(phases.withLock { $0 } == [.uploading, .transcribing])
    #expect(polls.withLock { $0 } == 2)
    let body = try #require(
      try JSONSerialization.jsonObject(with: submitted.withLock { $0 }) as? [String: Any])
    #expect(body["audio_url"] as? String == "https://cdn.example/abc")
    #expect(body["speaker_labels"] as? Bool == true)
    // Only documented fields, and nothing that pins a model or a language.
    #expect(Set(body.keys) == ["audio_url", "speaker_labels"])
  }

  @Test("a failed status check is retried; the transcription carries on")
  func pollRetry() async throws {
    let polls = Mutex(0)
    let transport = FakeHTTPTransport { request in
      switch request.url?.path {
      case "/v2/upload":
        return (200, json(["upload_url": "https://cdn.example/abc"]))

      case "/v2/transcript":
        return (200, json(["id": "t1", "status": "queued"]))

      default:
        let count = polls.withLock { polled in
          polled += 1
          return polled
        }
        return count == 1
          ? (503, Data())
          : (200, json(["id": "t1", "status": "completed", "text": "Done."]))
      }
    }
    let transcript = try await transcribeScratchFile(through: transport)
    #expect(transcript.text == "Done.")
    #expect(polls.withLock { $0 } == 2)
  }

  @Test("a transcript that ends in error throws its message")
  func asyncError() async throws {
    let transport = FakeHTTPTransport { request in
      request.url?.path == "/v2/upload"
        ? (200, json(["upload_url": "https://cdn.example/abc"]))
        : (200, json(["id": "t1", "status": "error", "error": "File has no audio."]))
    }
    await #expect(throws: AsyncTranscriptionError.failed("File has no audio.")) {
      try await transcribeScratchFile(through: transport)
    }
  }

  @Test("an HTTP failure carries the API's error sentence")
  func asyncHTTPError() async throws {
    let transport = FakeHTTPTransport { _ in (401, json(["error": "Invalid API key"])) }
    await #expect(throws: AsyncTranscriptionError.http(status: 401, message: "Invalid API key")) {
      try await transcribeScratchFile(through: transport)
    }
  }

  @Test("a failure body in no documented shape, a proxy's HTML, isn't shown to the user")
  func asyncUndocumentedError() async throws {
    let url = try scratchAudioFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let transport = FakeHTTPTransport { _ in (400, Data("<!DOCTYPE html><title>Blocked</title>".utf8)) }
    await #expect(throws: AsyncTranscriptionError.http(status: 400, message: nil)) {
      try await AsyncTranscriptionClient(transport: transport, pollInterval: .zero)
        .transcribe(fileAt: url, apiKey: "key")
    }
  }

  @Test("no API key fails before any request")
  func missingKey() async throws {
    let transcriber = FileTranscriber(
      client: AsyncTranscriptionClient(transport: FakeHTTPTransport { _ in (500, Data()) })
    ) { nil }
    await #expect(throws: BlurtError.self) {
      try await transcriber.transcribe(fileAt: URL(filePath: "/nonexistent.m4a"))
    }
  }

  // MARK: - Speaker turns

  private func transcript(_ object: [String: Any]) throws -> AsyncTranscript {
    try JSONDecoder().decode(AsyncTranscript.self, from: json(object))
  }

  @Test("several speakers are written one labelled turn per paragraph")
  func labelledTurns() throws {
    let transcript = try transcript([
      "id": "t", "status": "completed", "text": "Hi. Hello.",
      "utterances": [["speaker": "A", "text": "Hi."], ["speaker": "B", "text": "Hello."]],
    ])
    #expect(FileTranscriber.text(of: transcript) == "Speaker A: Hi.\n\nSpeaker B: Hello.")
  }

  @Test("a single speaker is the plain text, without labels")
  func singleSpeaker() throws {
    let transcript = try transcript([
      "id": "t", "status": "completed", "text": "Just me talking.",
      "utterances": [["speaker": "A", "text": "Just me talking."]],
    ])
    #expect(FileTranscriber.text(of: transcript) == "Just me talking.")
  }

  // MARK: - Transforms

  @Test("a transform is one gateway chat: its instruction as system, the transcript as user")
  func transformRequest() async throws {
    let captured = Mutex(Data())
    let transport = FakeHTTPTransport { request in
      #expect(request.url == GatewayChatClient.endpoint)
      captured.withLock { $0 = request.httpBody ?? Data() }
      return (200, json(["choices": [["message": ["content": "- Point one"], "finish_reason": "stop"]]]))
    }
    let reply = try await TranscriptLLM(apiKeyProvider: { "key" }, transport: transport)
      .apply(.keyPoints, to: "Speaker A: We ship Friday.")
    #expect(reply == "- Point one")
    let body = try #require(
      try JSONSerialization.jsonObject(with: captured.withLock { $0 }) as? [String: Any])
    #expect(body["model"] as? String == TranscriptLLM.tier.gatewayModel)
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages.first?["role"] == "system")
    #expect(messages.first?["content"] == TranscriptTransform.keyPoints.instruction)
    #expect(messages.last == ["role": "user", "content": "Speaker A: We ship Friday."])
  }

  @Test("every instruction starts from the shared frame; custom carries the user's words")
  func instructions() {
    let all: [TranscriptTransform] = [
      .meetingNotes, .summary, .keyPoints, .actionItems, .namedEntities, .speakerSummary, .speakerQuotes,
      .custom("Make it rhyme."),
    ]
    for transform in all { #expect(transform.instruction.hasPrefix(TranscriptTransform.frame)) }
    #expect(TranscriptTransform.custom("Make it rhyme.").instruction.hasSuffix("Make it rhyme."))
  }
}
