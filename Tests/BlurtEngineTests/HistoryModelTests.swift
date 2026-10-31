import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// The saved history's rules, file transcription end to end, the title
/// request, live partials, and the read-everything reader.
@Suite("History model")
struct HistoryModelTests {
  private func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  // MARK: - SavedTranscript rules

  @Test("each kind's audio, ownership and transcript rules")
  func kindRules() {
    let audio = URL(filePath: "/tmp/a.m4a")
    let dictation = SavedTranscript(kind: .dictation, date: .now, text: "Hi.")
    let read = SavedTranscript(kind: .readAloud, date: .now, text: "Hi.", fileURL: audio)
    let file = SavedTranscript(kind: .file, date: .now, text: "Hi.", fileURL: audio)
    let recording = SavedTranscript(kind: .recording, date: .now, text: "Hi.", fileURL: audio)
    #expect(!dictation.hasAudio && read.hasAudio && file.hasAudio && recording.hasAudio)
    #expect(!dictation.ownsAudio && read.ownsAudio && !file.ownsAudio && recording.ownsAudio)
    #expect(!dictation.isTranscript && !read.isTranscript && file.isTranscript && recording.isTranscript)
  }

  @Test("plain text is kept only where it differs, on creation and on replacement")
  func plainTextRule() {
    var entry = SavedTranscript(kind: .recording, date: .now, text: "Same.", plainText: "Same.")
    #expect(entry.plainText == nil)
    entry.replaceTranscript("Speaker A: Hi.\n\nSpeaker B: Hey.", plain: "Hi.\n\nHey.")
    #expect(entry.text.hasPrefix("Speaker A:"))
    #expect(entry.plainText == "Hi.\n\nHey.")
    entry.replaceTranscript("Just me.", plain: "Just me.")
    #expect(entry.plainText == nil)
  }

  @Test("an answer is titled by its text and keeps its request")
  func answerTitle() {
    let answer = SavedTranscript(kind: .readAloud, date: .now, text: "It's Friday.", request: "When do we ship?")
    #expect(answer.title == "It's Friday.")
    #expect(answer.request == "When do we ship?")
  }

  // MARK: - File transcription end to end

  @Test("a file comes back labelled by speaker, with the plain text beside it")
  func fileTranscriberBothWays() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "HistoryModelTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "call.m4a")
    try Data("audio".utf8).write(to: url)
    let transport = FakeHTTPTransport { request in
      switch request.url?.path {
      case "/v2/upload": return (200, self.json(["upload_url": "https://cdn.example/x"]))
      case "/v2/transcript": return (200, self.json(["id": "t", "status": "queued"]))
      default:
        return (
          200,
          self.json([
            "id": "t", "status": "completed", "text": "Hi. Hey.",
            "utterances": [["speaker": "A", "text": "Hi."], ["speaker": "B", "text": "Hey."]],
          ])
        )
      }
    }
    let transcriber = FileTranscriber(
      client: AsyncTranscriptionClient(transport: transport, pollInterval: .zero), apiKeyProvider: { "key" })
    let result = try await transcriber.transcribe(fileAt: url)
    #expect(result.text == "Speaker A: Hi.\n\nSpeaker B: Hey.")
    #expect(result.plainText == "Hi. Hey.")
    #expect(SpeakerTurn.parse(result.text).map(\.speaker) == ["A", "B"])
  }

  // MARK: - Titles

  @Test("a title is asked for from the transcript's opening, and comes back cleaned")
  func titleRequest() async throws {
    let sent = Mutex(Data())
    let transport = FakeHTTPTransport { request in
      sent.withLock { $0 = request.httpBody ?? Data() }
      return (200, self.json(["choices": [["message": ["content": "\"Launch Plan.\""], "finish_reason": "stop"]]]))
    }
    let long = String(repeating: "word ", count: 10_000)
    let title = try await TranscriptLLM(apiKeyProvider: { "key" }, transport: transport).title(for: long)
    #expect(title == "Launch Plan")
    let body = try #require(try JSONSerialization.jsonObject(with: sent.withLock { $0 }) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: String]])
    #expect(messages.first?["content"] == TranscriptLLM.titleInstruction)
    #expect(messages.last?["content"]?.count == TranscriptLLM.titleSourceCharacters)
    #expect(body["model"] as? String == TranscriptLLM.model)
  }

  @Test("no key, no title request")
  func titleNeedsKey() async {
    await #expect(throws: BlurtError.self) {
      try await TranscriptLLM(apiKeyProvider: { nil }, transport: FakeHTTPTransport { _ in (500, Data()) })
        .title(for: "Hi.")
    }
  }

  // MARK: - Live partials

  @Test("the partial is the turn being spoken, cleared when it settles")
  func livePartial() {
    var live = LiveTranscript()
    #expect(live.partial == nil)
    live.apply(RealtimeTurn(order: 0, transcript: "so the", isFinal: false, speaker: nil))
    #expect(live.partial == "so the")
    live.apply(RealtimeTurn(order: 0, transcript: "So the plan.", isFinal: true, speaker: nil))
    #expect(live.partial == nil)
    #expect(live.text == "So the plan.")
  }

  // MARK: - Relative time

  @Test("the relative label takes the caller's first-minute wording")
  func relativeLabelWording() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(now.relativeLabel(now: now) == "just now")
    #expect(now.relativeLabel(now: now, justNow: "less than 1 minute ago") == "less than 1 minute ago")
    #expect(
      now.relativeLabel(now: now.addingTimeInterval(120), locale: Locale(identifier: "en_US")) == "2 minutes ago")
  }

  // MARK: - TextReader

  @Test("text is read verbatim in the read-aloud voice — no skip-jargon rewrite")
  func textReaderVerbatim() async throws {
    let speaker = GatedSpeaker()
    speaker.finishAll()
    try await TextReader(speaker: speaker).read("Meeting notes.")
    let calls = speaker.calls
    #expect(calls.count == 1)
    #expect(calls.first?.kind == "speak: Meeting notes.")
    #expect(calls.first?.style.skipsJargon == false)
  }
}
