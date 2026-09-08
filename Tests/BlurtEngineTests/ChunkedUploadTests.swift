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

  @Test("a cancel during transcribing cancels the request, not just the wait")
  func cancelDuringTranscribingCancelsUpload() async throws {
    // The window after release and before the response: the feed has ended and
    // the request is waiting on inference. Cancelling the pipeline only
    // abandons the *wait* — awaiting a `Task`'s value is not cancellation-aware
    // — so the request has to be cancelled by name or it runs to completion and
    // transcribes a dictation the user dismissed.
    let probe = LateProbe(transcript: "Hello world.")
    let session = DictationSession(
      mic: StubMicCapture(), transcriber: probe, injector: StubInjector(),
      keyTermsProvider: { [] }, seams: .offline)

    await session.press()
    await session.release()
    await probe.waitUntilAwaitingResponse()
    #expect(await session.phase == .transcribing)

    await session.cancel()
    #expect(await session.phase == .cancelled)
    probe.allowToFinish()
    await session.awaitPipeline()

    #expect(probe.sawCancellation)
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

  @Test("upload progress accounts the audio it has actually sent")
  func uploadProgressAccountsAudio() {
    let progress = UploadProgress()
    // Nothing sent yet: there is no "last frame" instant to measure post-speech
    // latency from, which is what nil means to the log line.
    #expect(progress.audioBytes == 0)
    #expect(progress.lastFrameAt == nil)

    progress.recordFrame(bytes: 3_200)
    let first = progress.lastFrameAt
    #expect(progress.audioBytes == 3_200)
    #expect(first != nil)

    progress.recordFrame(bytes: 1_600)
    // Bytes accumulate; the instant tracks the *latest* frame, because that is
    // the one the user stopped talking at.
    #expect(progress.audioBytes == 4_800)
    #expect(progress.lastFrameAt ?? .now >= first ?? .now)
  }

  @Test("URLSession is refused a second copy of the body, never handed an empty one")
  func replayIsRefused() async {
    // One of the three no-fallback guarantees. URLSession asks for a fresh body
    // stream whenever it has to send the request again — an auth challenge, a
    // 307, a connection retry it handles internally. A recording that has
    // already been streamed is gone, so the honest answer is nil, which fails
    // the request. Handing back anything else would re-send the dictation with
    // no audio in it and return a blank transcript.
    let metrics = MetricsLogger(progress: UploadProgress())
    // Never resumed — the delegate ignores both arguments, so an idle task is
    // enough to exercise the contract without touching the network.
    let task = URLSession.shared.dataTask(with: URL(staticString: "https://example.invalid"))

    let replacement = await metrics.urlSession(.shared, needNewBodyStreamForTask: task)

    #expect(replacement == nil)
  }

  @Test("a reader that goes away fails the write instead of dropping audio")
  func closedReaderFailsTheWrite() async throws {
    let body = try ChunkedRequestBody()
    // Stands in for URLSession abandoning the body — an early 401, or a replay
    // it asked for and was refused. The pipe can then stop accepting bytes
    // without ever reporting itself writable, so this has to fail rather than
    // poll forever or silently discard the rest of the recording.
    body.input.open()
    body.input.close()
    let chunk = Data(count: 128 * 1024)  // larger than the pipe's buffer

    await #expect(throws: (any Error).self) {
      try await body.drain(
        AsyncThrowingStream { continuation in
          continuation.yield(chunk)
          continuation.finish()
        })
    }
  }

  @Test("cancelling the upload stops the writer instead of parking on a full pipe")
  func cancellationUnblocksTheWriter() async throws {
    let body = try ChunkedRequestBody()
    // Nobody ever reads, so the pipe fills and the writer lands in its
    // backpressure loop. Cancellation is what has to get it out — the transport
    // relies on exactly this when the response arrives before the body is done.
    let writer = Task {
      try await body.drain(
        AsyncThrowingStream { continuation in
          continuation.yield(Data(count: 512 * 1024))
          continuation.finish()
        })
    }
    // Let it reach the loop before cancelling, so this exercises the wait rather
    // than the pre-flight `checkCancellation`.
    try await Task.sleep(for: .milliseconds(50))
    writer.cancel()

    await #expect(throws: CancellationError.self) { try await writer.value }
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

/// Transcriber double that parks *after* the feed ends — i.e. where a real
/// request waits for inference — so a cancel can be landed while the session is
/// `.transcribing` and the request is still open.
private final class LateProbe: TranscriberProtocol, @unchecked Sendable {
  private let transcript: String
  private let awaiting = AsyncGate()
  private let release = AsyncGate()
  private let cancelled = Mutex(false)

  init(transcript: String) { self.transcript = transcript }

  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int,
    resolveContext: @escaping @Sendable () async -> TranscriptionContext?
  ) async throws -> String {
    for await _ in frames {}
    _ = await resolveContext()
    awaiting.open()
    await release.wait()
    // Read after the gate so the test controls when this is sampled. A real
    // request would have been torn down by the cancellation itself.
    cancelled.withLock { $0 = Task.isCancelled }
    return transcript
  }

  func waitUntilAwaitingResponse() async { await awaiting.wait() }
  func allowToFinish() { release.open() }
  var sawCancellation: Bool { cancelled.withLock { $0 } }
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
