import Foundation
import Testing

@testable import BlurtEngine

@Suite("STTRouter")
struct STTRouterTests {
  @Test("recordingBelowCutoffUsesDictationAPI")
  func recordingBelowCutoffUsesDictationAPI() async throws {
    let short = ShortClient()
    let long = LongClient()
    let writer = RoutingAudioWriter()
    let (frames, feed) = AsyncStream.makeStream(of: Data.self)
    let session = STTRouter(shortClient: short, longClient: long).start(
      frames: frames, writer: writer, context: nil, vocabulary: [])
    feed.yield(Data([1]))
    feed.finish()
    let result = try await session.stop(
      durationSeconds: 10, audioFileURL: URL(fileURLWithPath: "/tmp/test.wav"))
    #expect(result.mode == .short)
    #expect(result.raw == "short raw")
    #expect(short.calls == 1)
    #expect(long.calls == 0)
  }

  @Test("recordingBeyondCutoffUsesAsyncAPI")
  func recordingBeyondCutoffUsesAsyncAPI() async throws {
    let short = ShortClient()
    let long = LongClient()
    let writer = RoutingAudioWriter()
    let (frames, feed) = AsyncStream.makeStream(of: Data.self)
    let session = STTRouter(shortClient: short, longClient: long).start(
      frames: frames, writer: writer, context: nil, vocabulary: ["Swift"])
    feed.yield(Data([1]))
    feed.finish()
    let result = try await session.stop(
      durationSeconds: 116, audioFileURL: URL(fileURLWithPath: "/tmp/test.wav"))
    #expect(result.mode == .long)
    #expect(result.raw == "long raw")
    #expect(long.calls == 1)
    #expect(long.vocabulary == ["Swift"])
  }

  @Test("recordingBeyondCutoffCancelsShortRequest")
  func recordingBeyondCutoffCancelsShortRequest() async throws {
    let short = ShortClient(waitForCancellation: true)
    let long = LongClient()
    let writer = RoutingAudioWriter()
    let (frames, feed) = AsyncStream.makeStream(of: Data.self)
    let session = STTRouter(shortClient: short, longClient: long).start(
      frames: frames, writer: writer, context: nil, vocabulary: [])
    feed.finish()
    _ = try await session.stop(
      durationSeconds: 116, audioFileURL: URL(fileURLWithPath: "/tmp/test.wav"))
    // Cancellation is immediate, but the client observes it on its own task.
    for _ in 0..<100 where short.calls > 0 && !short.cancelled {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(short.calls == 0 || short.cancelled)
  }
}

private final class ShortClient: ShortSTTClient, Sendable {
  private struct State {
    var calls = 0
    var cancelled = false
  }
  private let state = Mutex(State())
  private let waitForCancellation: Bool
  init(waitForCancellation: Bool = false) { self.waitForCancellation = waitForCancellation }
  func transcribeShort(
    frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
  ) async throws -> ShortTranscription {
    state.withLock { $0.calls += 1 }
    for await _ in frames {}
    if waitForCancellation {
      do { try await Task.sleep(for: .seconds(60)) } catch {
        state.withLock { $0.cancelled = true }
        throw error
      }
    }
    return ShortTranscription(raw: "short raw", assemblyClean: "short clean")
  }
  var calls: Int { state.withLock { $0.calls } }
  var cancelled: Bool { state.withLock { $0.cancelled } }
}

private final class LongClient: LongSTTClient, Sendable {
  private struct State {
    var calls = 0
    var vocabulary: [String] = []
  }
  private let state = Mutex(State())
  func transcribe(audioFileURL: URL, vocabulary: [String]) async throws -> String {
    state.withLock { $0 = State(calls: $0.calls + 1, vocabulary: vocabulary) }
    return "long raw"
  }
  var calls: Int { state.withLock { $0.calls } }
  var vocabulary: [String] { state.withLock { $0.vocabulary } }
}

private final class RoutingAudioWriter: LocalAudioWriter, Sendable {
  var relativePath: String { get async { "Audio/test.wav" } }
  var fileURL: URL { get async { URL(fileURLWithPath: "/tmp/test.wav") } }
  func append(_ pcm: Data) async throws {}
  func finish() async throws {}
  func cancelAndDelete() async {}
}
