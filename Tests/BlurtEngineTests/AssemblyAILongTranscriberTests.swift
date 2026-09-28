import Foundation
import Testing

@testable import BlurtEngine

@Suite("AssemblyAI Universal-2 upload")
struct AssemblyAILongTranscriberTests {
  @Test("uploads completed WAV, submits Universal-2, polls, and returns text")
  func uploadAndPoll() async throws {
    let audio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
    try Data([1, 2, 3, 4]).write(to: audio)
    defer { try? FileManager.default.removeItem(at: audio) }
    let requests = Mutex([URLRequest]())
    let transport = FakeHTTPTransport { request in
      requests.withLock { $0.append(request) }
      switch request.url?.path {
      case "/v2/upload":
        return (200, json(["upload_url": "https://example.test/audio.wav"]))
      case "/v2/transcript":
        return (200, json(["id": "job-1", "status": "processing"]))
      default:
        return (200, json(["id": "job-1", "status": "completed", "text": " Готово "]))
      }
    }
    let client = AssemblyAILongTranscriber(
      apiKeyProvider: { "test-key" }, transport: transport,
      baseURL: URL(string: "https://example.test")!, pollDelay: .zero)
    let text = try await client.transcribe(audioFileURL: audio, vocabulary: ["Swift", "swift"])
    #expect(text == "Готово")
    let sent = requests.withLock { $0 }
    #expect(sent.map(\.httpMethod) == ["POST", "POST", "GET"])
    #expect(sent[0].httpBody == Data([1, 2, 3, 4]))
    #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "test-key" })
    let body = try #require(sent[1].httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["speech_models"] as? [String] == ["universal-2"])
    #expect(payload["language_code"] as? String == "ru")
    #expect(payload["word_boost"] as? [String] == ["Swift"])
  }

  @Test("missing key fails before opening audio")
  func missingKey() async {
    let client = AssemblyAILongTranscriber(apiKeyProvider: { nil })
    await #expect(throws: BlurtError.self) {
      try await client.transcribe(audioFileURL: URL(fileURLWithPath: "/nonexistent.wav"), vocabulary: [])
    }
  }

  @Test("HTTP and transcript failures are surfaced")
  func errors() async throws {
    let audio = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
    try Data([1]).write(to: audio)
    defer { try? FileManager.default.removeItem(at: audio) }
    let rejected = AssemblyAILongTranscriber(
      apiKeyProvider: { "key" },
      transport: FakeHTTPTransport { _ in (401, Data()) })
    await #expect(throws: AssemblyAILongError.httpStatus(401)) {
      try await rejected.transcribe(audioFileURL: audio, vocabulary: [])
    }
    let failed = AssemblyAILongTranscriber(
      apiKeyProvider: { "key" },
      transport: FakeHTTPTransport { request in
        if request.url?.path == "/v2/upload" {
          return (200, json(["upload_url": "https://example.test/audio.wav"]))
        }
        return (200, json(["id": "job-1", "status": "error", "error": "bad audio"]))
      })
    await #expect(throws: AssemblyAILongError.transcriptionFailed("bad audio")) {
      try await failed.transcribe(audioFileURL: audio, vocabulary: [])
    }
  }
}
