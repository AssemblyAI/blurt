import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

@Suite("Chunked upload", .timeLimit(.minutes(1)))
struct ChunkedUploadTests {

  @Test("the request opens at press and streams, rather than waiting for release")
  func requestOpensAtPress() async throws {
    // The entire point of the change: if the request only opened at release,
    // the upload would sit on the wait the user feels. `entered` flips as soon
    // as the transcriber is called, which is observable *while* recording.
    let probe = UploadProbe(transcript: "Hello world.")
    let session = DictationSession(
      mic: StubMicCapture(), transcriber: probe, injector: StubInjector(),
      keyTermsProvider: { [] }, seams: .offline)

    await session.press()
    // Still recording — nothing has been released, stopped, or awaited.
    #expect(await session.phase == .recording)
    await probe.waitUntilEntered()
    #expect(probe.enteredWhileRecording)
  }

  @Test("the frame feed ends at release, which is what completes the body")
  func framesEndAtRelease() async throws {
    let probe = UploadProbe(transcript: "Hello world.")
    let session = DictationSession(
      mic: StubMicCapture(), transcriber: probe, injector: StubInjector(),
      keyTermsProvider: { [] }, seams: .offline)

    await session.press()
    await probe.waitUntilEntered()
    // The producer is parked on the feed: the recording is still open, so the
    // config part must not have been written yet.
    #expect(probe.framesFinished == false)

    await session.release()
    await session.waitForIdle()

    // Release ended the feed, and only then was the context resolved — the
    // ordering the config-part-last framing depends on.
    #expect(probe.framesFinished)
    #expect(probe.contextResolvedAfterFrames)
    #expect(await session.phase == .pasted)
  }

  @Test("a cancel while recording abandons the in-flight request")
  func cancelWhileRecordingAbandonsUpload() async throws {
    let probe = UploadProbe(transcript: "Hello world.")
    let injector = StubInjector()
    let session = DictationSession(
      mic: StubMicCapture(), transcriber: probe, injector: injector,
      keyTermsProvider: { [] }, seams: .offline)

    await session.press()
    await probe.waitUntilEntered()
    await session.cancel()
    await session.waitForIdle()

    #expect(await session.phase == .cancelled)
    // The request was cancelled, not completed: nothing was pasted, and the
    // transcript the probe would have returned never arrived. Without
    // `cancelUpload()` the streamed body would finish on its own and transcribe
    // audio the user discarded.
    #expect(await injector.inserted.isEmpty)
    #expect(probe.completions == 0)
  }

  @Test("a too-short clip abandons the request instead of completing it")
  func tooShortClipAbandonsUpload() async throws {
    let mic = StubMicCapture()
    // Below `minPCMBytes` — an accidental tap. The request is already open and
    // carrying those bytes, so the guard has to cancel it rather than let it
    // finish and earn a 400.
    await mic.setPCM(Data(count: 8))
    let probe = UploadProbe(transcript: "Hello world.")
    let injector = StubInjector()
    let session = DictationSession(
      mic: mic, transcriber: probe, injector: injector,
      keyTermsProvider: { [] }, seams: .offline)

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .idle)
    #expect(await injector.inserted.isEmpty)
    #expect(probe.completions == 0)
  }

  @Test("the body pipe delivers every chunk, in order")
  func pipeDeliversChunksInOrder() async throws {
    let body = try ChunkedRequestBody()
    let chunks = [Data("first".utf8), Data("second".utf8), Data("third".utf8)]
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }

    // The reader stands in for URLSession: it owns the input end and drains it
    // until the writer closes, which is what marks the body complete.
    let reader = Task.detached { () -> Data in
      body.input.open()
      defer { body.input.close() }
      var received = Data()
      var buffer = [UInt8](repeating: 0, count: 64)
      while true {
        let read = body.input.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        received.append(contentsOf: buffer[0..<read])
      }
      return received
    }
    try await body.drain(stream)

    #expect(await reader.value == Data("firstsecondthird".utf8))
  }

  @Test("a producer failure surfaces rather than truncating the body silently")
  func producerFailurePropagates() async throws {
    let body = try ChunkedRequestBody()
    let stream = AsyncThrowingStream<Data, any Error> { continuation in
      continuation.yield(Data("partial".utf8))
      // Stands in for the `config` part failing to encode: the body can no
      // longer be completed, and the server would only report a generic 400.
      continuation.finish(throwing: ChunkedUploadError.uploadNeverStarted)
    }
    let reader = Task.detached {
      body.input.open()
      defer { body.input.close() }
      var buffer = [UInt8](repeating: 0, count: 64)
      while body.input.read(&buffer, maxLength: buffer.count) > 0 {}
    }

    await #expect(throws: ChunkedUploadError.self) {
      try await body.drain(stream)
    }
    await reader.value
  }
}

/// Transcriber double that reports *when* it was called and in what order it
/// consumed the feed — the two facts the chunked upload turns on and that a
/// return-value-only stub cannot show.
private final class UploadProbe: TranscriberProtocol, @unchecked Sendable {
  private struct State {
    var entered = false
    var framesFinished = false
    var contextResolvedAfterFrames = false
    var completions = 0
  }

  private let transcript: String
  private let state = Mutex(State())
  /// Opened the moment `transcribe` is entered, so a test can wait for the
  /// request to be in flight without polling a phase that never changes. A bare
  /// `AsyncGate`, not `Gate`: the probe must *not* block on entry — it parks on
  /// the frame feed instead, which is where the production producer waits.
  private let entered = AsyncGate()

  init(transcript: String) { self.transcript = transcript }

  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int,
    resolveContext: @escaping @Sendable () async -> TranscriptionContext?
  ) async throws -> String {
    state.withLock { $0.entered = true }
    entered.open()
    // Parks here until the session ends the feed at release — exactly where the
    // production producer sits while the user is speaking.
    for await _ in frames {}
    state.withLock { $0.framesFinished = true }
    _ = await resolveContext()
    state.withLock {
      $0.contextResolvedAfterFrames = $0.framesFinished
      $0.completions += 1
    }
    return transcript
  }

  /// Suspends until `transcribe` has been entered.
  func waitUntilEntered() async { await entered.wait() }

  var enteredWhileRecording: Bool { state.withLock { $0.entered } }
  var framesFinished: Bool { state.withLock { $0.framesFinished } }
  var contextResolvedAfterFrames: Bool { state.withLock { $0.contextResolvedAfterFrames } }
  var completions: Int { state.withLock { $0.completions } }
}
