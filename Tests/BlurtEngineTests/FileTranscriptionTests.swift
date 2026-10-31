import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// File transcription: the async API's upload → submit → poll flow, how
/// speaker turns are written out, the gateway transforms, and the saved history.
@Suite("File transcription")
struct FileTranscriptionTests {
  private func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  /// A fresh directory holding one small file to "upload".
  private func audioFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "FileTranscriptionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "call.m4a")
    try Data("audio bytes".utf8).write(to: url)
    return url
  }

  // MARK: - Async API

  @Test("uploads the raw file, submits it with speaker labels, polls until completed")
  func asyncFlow() async throws {
    let url = try audioFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let polls = Mutex(0)
    let submitted = Mutex(Data())
    let transport = FakeHTTPTransport { request in
      let path = request.url?.path ?? ""
      #expect(request.value(forHTTPHeaderField: "Authorization") == "key")
      switch (request.httpMethod, path) {
      case ("POST", "/v2/upload"):
        #expect(request.httpBody == Data("audio bytes".utf8))
        return (200, self.json(["upload_url": "https://cdn.example/abc"]))
      case ("POST", "/v2/transcript"):
        submitted.withLock { $0 = request.httpBody ?? Data() }
        return (200, self.json(["id": "t1", "status": "queued"]))
      case ("GET", "/v2/transcript/t1"):
        let count = polls.withLock {
          $0 += 1
          return $0
        }
        return count < 2
          ? (200, self.json(["id": "t1", "status": "processing"]))
          : (200, self.json(["id": "t1", "status": "completed", "text": "Hello there."]))
      default:
        Issue.record("unexpected request \(request.httpMethod ?? "") \(path)")
        return (500, Data())
      }
    }
    let client = AsyncTranscriptionClient(transport: transport, pollInterval: .zero)
    let phases = Mutex<[AsyncTranscriptionClient.Phase]>([])
    let transcript = try await client.transcribe(fileAt: url, apiKey: "key") { phase in
      phases.withLock { $0.append(phase) }
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
    let url = try audioFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let polls = Mutex(0)
    let transport = FakeHTTPTransport { request in
      switch request.url?.path {
      case "/v2/upload": return (200, self.json(["upload_url": "https://cdn.example/abc"]))
      case "/v2/transcript": return (200, self.json(["id": "t1", "status": "queued"]))
      default:
        let count = polls.withLock {
          $0 += 1
          return $0
        }
        return count == 1
          ? (503, Data())
          : (200, self.json(["id": "t1", "status": "completed", "text": "Done."]))
      }
    }
    let transcript = try await AsyncTranscriptionClient(transport: transport, pollInterval: .zero)
      .transcribe(fileAt: url, apiKey: "key")
    #expect(transcript.text == "Done.")
    #expect(polls.withLock { $0 } == 2)
  }

  @Test("a transcript that ends in error throws its message")
  func asyncError() async throws {
    let url = try audioFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let transport = FakeHTTPTransport { request in
      request.url?.path == "/v2/upload"
        ? (200, self.json(["upload_url": "https://cdn.example/abc"]))
        : (200, self.json(["id": "t1", "status": "error", "error": "File has no audio."]))
    }
    await #expect(throws: AsyncTranscriptionError.failed("File has no audio.")) {
      try await AsyncTranscriptionClient(transport: transport, pollInterval: .zero)
        .transcribe(fileAt: url, apiKey: "key")
    }
  }

  @Test("an HTTP failure carries the API's error sentence")
  func asyncHTTPError() async throws {
    let url = try audioFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let transport = FakeHTTPTransport { _ in (401, self.json(["error": "Invalid API key"])) }
    await #expect(throws: AsyncTranscriptionError.http(status: 401, message: "Invalid API key")) {
      try await AsyncTranscriptionClient(transport: transport, pollInterval: .zero)
        .transcribe(fileAt: url, apiKey: "key")
    }
  }

  @Test("no API key fails before any request")
  func missingKey() async throws {
    let transcriber = FileTranscriber(
      client: AsyncTranscriptionClient(transport: FakeHTTPTransport { _ in (500, Data()) }),
      apiKeyProvider: { nil })
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
      #expect(request.url == ReadAloudLLM.endpoint)
      captured.withLock { $0 = request.httpBody ?? Data() }
      return (200, self.json(["choices": [["message": ["content": "- Point one"], "finish_reason": "stop"]]]))
    }
    let reply = try await TranscriptLLM(apiKeyProvider: { "key" }, transport: transport)
      .apply(.keyPoints, to: "Speaker A: We ship Friday.")
    #expect(reply == "- Point one")
    let body = try #require(
      try JSONSerialization.jsonObject(with: captured.withLock { $0 }) as? [String: Any])
    #expect(body["model"] as? String == TranscriptLLM.model)
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

  // MARK: - History

  @Test("the history round-trips every kind, newest first, with every entry kept")
  func storeRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TranscriptStoreTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TranscriptStore(url: directory.appending(path: "history.json"))
    #expect(store.load().isEmpty)
    // Whole seconds: the dates are written ISO 8601, which keeps no fraction.
    let date = Date(timeIntervalSince1970: 1_793_380_962)
    let entries =
      [
        SavedTranscript(kind: .dictation, date: date, text: "Ship it Friday.", style: "Formal"),
        SavedTranscript(
          kind: .recording, date: date, text: "Speaker A: Hi.", fileURL: URL(filePath: "/tmp/Recording.m4a"),
          plainText: "Hi.", generatedTitle: "Greeting", results: ["summary": "Short."], customRequest: "Rhyme it."),
      ]
      + (0..<120).map {
        SavedTranscript(kind: .file, date: date, text: "Text \($0)", fileURL: URL(filePath: "/tmp/\($0).m4a"))
      }
    try store.save(entries)
    #expect(store.load() == entries)
  }

  @Test("a dictation is titled by what was said; a file by its name")
  func titles() {
    #expect(SavedTranscript(kind: .dictation, date: .now, text: "Ship it Friday.").title == "Ship it Friday.")
    #expect(
      SavedTranscript(kind: .file, date: .now, text: "…", fileURL: URL(filePath: "/tmp/call.m4a")).title == "call.m4a")
  }

  @Test("a history that won't decode is moved aside, not overwritten")
  func corruptStore() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TranscriptStoreTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "history.json")
    try Data("not json".utf8).write(to: url)
    #expect(TranscriptStore(url: url).load().isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.contains { $0.hasPrefix("history.corrupt-") })
    #expect(!names.contains("history.json"))
  }

  @Test("one entry that won't decode is skipped, and the file backed up first; the rest load")
  func lossyStore() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "TranscriptStoreTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TranscriptStore(url: directory.appending(path: "history.json"))
    let good = SavedTranscript(kind: .dictation, date: Date(timeIntervalSince1970: 1_793_380_962), text: "Kept.")
    try store.save([good])
    // A second entry of a kind this build doesn't know, as a newer build might write.
    var json = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "history.json")))
        as? [[String: Any]])
    var future = json[0]
    future["id"] = UUID().uuidString
    future["kind"] = "hologram"
    json.append(future)
    try JSONSerialization.data(withJSONObject: json).write(to: directory.appending(path: "history.json"))

    #expect(store.load() == [good])
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names.contains { $0.hasPrefix("history.backup-") })
    #expect(names.contains("history.json"))
  }

  @Test("file stamps go to the millisecond, so two in one second differ")
  func fileStamp() {
    let date = Date(timeIntervalSince1970: 1_793_380_962.123)
    let stamp = TranscriptStore.fileStamp(date)
    #expect(stamp.hasSuffix(".123"))
    #expect(stamp != TranscriptStore.fileStamp(date.addingTimeInterval(0.001)))
  }

  @Test("a user's file is found through its bookmark after a move")
  func bookmarkFollowsMove() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "BookmarkTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appending(path: "call.m4a")
    try Data("audio".utf8).write(to: original)
    let entry = SavedTranscript(kind: .file, date: .now, text: "Hi.", fileURL: original)
    let moved = directory.appending(path: "renamed.m4a")
    try FileManager.default.moveItem(at: original, to: moved)
    #expect(entry.audioURL?.lastPathComponent == "renamed.m4a")
    // A recording keeps its path; no bookmark.
    #expect(SavedTranscript(kind: .recording, date: .now, text: "Hi.", fileURL: moved).fileBookmark == nil)
  }
}
