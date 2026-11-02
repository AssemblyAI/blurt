import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// Read-aloud clips: the WAV a read's audio is kept in, and the speaker
/// reporting each finished read with it.
@Suite("Read clips")
struct ReadClipTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "ReadClipTests-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("the WAV header carries the sizes once finished")
  func wavWriter() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let writer = try WAVWriter(url: folder.appending(path: "clip.wav"), sampleRate: 24_000)
    writer.append(Data(repeating: 1, count: 100))
    writer.append(Data(repeating: 2, count: 60))
    #expect(writer.finish() == 160)
    #expect(writer.finish() == 160)  // idempotent
    writer.append(Data(count: 10))  // after finish: ignored
    let data = try Data(contentsOf: writer.url)
    #expect(data.count == 44 + 160)
    #expect(data.prefix(4) == Data("RIFF".utf8))
    #expect(data == WAVWriter.header(sampleRate: 24_000, dataBytes: 160) + data.dropFirst(44))
  }

  @Test("a clip never overwrites another's file")
  func noOverwrite() throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "clip.wav")
    let first = try WAVWriter(url: url, sampleRate: 24_000)
    first.append(Data(repeating: 7, count: 10))
    first.finish()
    #expect(throws: (any Error).self) { try WAVWriter(url: url, sampleRate: 24_000) }
    #expect(try Data(contentsOf: url).count == 44 + 10)
  }

  @Test("a read is reported as a clip holding what played")
  func speakerReportsClip() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let clips = Mutex<[ReadClip]>([])
    let speaker = SelectionSpeaker(
      synthesizer: AssemblyAISpeechSynthesizer(apiKeyProvider: { "k" }, transport: FakeSpeechTransport()),
      llm: ReadAloudLLM(apiKeyProvider: { "k" }, transport: FakeHTTPTransport.failing(with: URLError(.timedOut))),
      clips: ReadClipSink(directory: folder) { clip in clips.withLock { $0.append(clip) } },
      makeSink: { _ in RecordingSink() })
    try await speaker.speak(
      "Read this.", style: ReadAloudStyle(rate: 1, skipsJargon: false), onLevel: nil)
    let clip = try #require(clips.withLock { $0.first })
    #expect(clip.text == "Read this.")
    #expect(clip.request == nil)
    let audio = try Data(contentsOf: clip.audioURL)
    #expect(audio.count > 44)
    #expect(audio.prefix(4) == Data("RIFF".utf8))
  }

  @Test("a read that produced no audio leaves no clip and no file")
  func emptyReadLeavesNothing() async throws {
    let folder = try directory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let clips = Mutex(0)
    let speaker = SelectionSpeaker(
      synthesizer: AssemblyAISpeechSynthesizer(
        apiKeyProvider: { "k" }, transport: FakeSpeechTransport(failing: URLError(.timedOut))),
      llm: ReadAloudLLM(apiKeyProvider: { "k" }, transport: FakeHTTPTransport.failing(with: URLError(.timedOut))),
      clips: ReadClipSink(directory: folder) { _ in clips.withLock { $0 += 1 } },
      makeSink: { _ in RecordingSink() })
    _ = try? await speaker.speak(
      "Read this.", style: ReadAloudStyle(rate: 1, skipsJargon: false), onLevel: nil)
    #expect(clips.withLock { $0 } == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  @Test("a model's title is cleaned of quotes, a Title: lead and a full stop")
  func cleanTitle() {
    #expect(TranscriptLLM.cleanTitle("\"Quarterly Pipeline Review.\"") == "Quarterly Pipeline Review")
    #expect(TranscriptLLM.cleanTitle("Title: Hiring Plan for Q3\nExtra line") == "Hiring Plan for Q3")
    #expect(TranscriptLLM.cleanTitle("  \"\"  ") == nil)
  }

  @Test("a recording's LLM title replaces its file name; a read clip is titled by its text")
  func titles() {
    var recording = SavedTranscript(
      kind: .recording, date: .now, text: "…", fileURL: URL(filePath: "/tmp/Recording.m4a"))
    #expect(recording.title == "Recording.m4a")
    recording.generatedTitle = "Pipeline Review"
    #expect(recording.title == "Pipeline Review")
    let read = SavedTranscript(
      kind: .readAloud, date: .now, text: "The selection.", fileURL: URL(filePath: "/tmp/r.wav"))
    #expect(read.title == "The selection.")
  }
}
