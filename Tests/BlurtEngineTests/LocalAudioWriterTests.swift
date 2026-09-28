import Foundation
import Testing

@testable import BlurtEngine

@Suite("Local audio persistence")
struct LocalAudioWriterTests {
  @Test("recordingBeyondCutoffKeepsFullLocalAudio")
  func recordingBeyondCutoffKeepsFullLocalAudio() async throws {
    let writer = RecordingAudioWriter()
    let (source, feed) = AsyncStream.makeStream(of: Data.self)
    let fanout = PCMFrameFanout(source: source, writer: writer)
    let shortConsumer = Task {
      var first = true
      for await _ in fanout.shortFrames {
        if first {
          first = false
          break
        }
      }
    }

    feed.yield(Data([1, 2]))
    await shortConsumer.value
    feed.yield(Data([3, 4]))
    feed.finish()
    try await fanout.completion.value

    #expect(writer.bytes == Data([1, 2, 3, 4]))
    #expect(writer.didFinish)
  }

  @Test("WAV header describes PCM S16LE 16kHz mono")
  func wavHeader() {
    let header = WAVAudioWriter.header(audioBytes: 320)
    #expect(header.count == 44)
    #expect(String(data: header[0..<4], encoding: .ascii) == "RIFF")
    #expect(String(data: header[8..<12], encoding: .ascii) == "WAVE")
    #expect(header[22] == 1)
    #expect(header[24] == 0x80 && header[25] == 0x3e)
    #expect(header[34] == 16)
  }

  @Test("finished WAV contains every frame and its final byte count")
  func finishedWAV() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    let writer = try WAVAudioWriter(jobID: id, baseDirectory: directory)
    #expect(await writer.relativePath == "Audio/\(id.uuidString).wav")
    try await writer.append(Data([1, 2]))
    try await writer.append(Data([3, 4]))
    try await writer.finish()
    try await writer.finish()
    let data = try Data(contentsOf: await writer.fileURL)
    #expect(data.count == 48)
    #expect(data[40..<44] == Data([4, 0, 0, 0]))
    #expect(data[44..<48] == Data([1, 2, 3, 4]))
  }

  @Test("cancel removes unfinished WAV")
  func cancelWAV() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = try WAVAudioWriter(jobID: UUID(), baseDirectory: directory)
    try await writer.append(Data([1, 2]))
    let url = await writer.fileURL
    #expect(FileManager.default.fileExists(atPath: url.path))
    await writer.cancelAndDelete()
    await writer.cancelAndDelete()
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("failed local write terminates both fanout consumers")
  func failedFanout() async {
    let (source, feed) = AsyncStream.makeStream(of: Data.self)
    let fanout = PCMFrameFanout(source: source, writer: FailingAudioWriter())
    feed.yield(Data([1]))
    feed.finish()
    await #expect(throws: AudioWriteFailure.failed) {
      try await fanout.completion.value
    }
    var iterator = fanout.shortFrames.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    fanout.stopShortFeed()
  }
}

private enum AudioWriteFailure: Error, Equatable { case failed }

private struct FailingAudioWriter: LocalAudioWriter {
  var relativePath: String { get async { "Audio/failed.wav" } }
  var fileURL: URL { get async { URL(fileURLWithPath: "/tmp/failed.wav") } }
  func append(_ pcm: Data) async throws { throw AudioWriteFailure.failed }
  func finish() async throws {}
  func cancelAndDelete() async {}
}

private final class RecordingAudioWriter: LocalAudioWriter, Sendable {
  private struct State {
    var bytes = Data()
    var finished = false
  }
  private let state = Mutex(State())
  var relativePath: String { get async { "Audio/test.wav" } }
  var fileURL: URL { get async { URL(fileURLWithPath: "/tmp/test.wav") } }
  func append(_ pcm: Data) async throws { state.withLock { $0.bytes.append(pcm) } }
  func finish() async throws { state.withLock { $0.finished = true } }
  func cancelAndDelete() async { state.withLock { $0 = State() } }
  var bytes: Data { state.withLock { $0.bytes } }
  var didFinish: Bool { state.withLock { $0.finished } }
}
