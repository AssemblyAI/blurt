import Foundation
import Testing

@testable import BlurtEngine

@Suite("Chunked upload", .timeLimit(.minutes(1)))
struct ChunkedUploadTests {

  @Test("the request opens at press and streams, rather than waiting for release")
  func requestOpensAtPress() async throws {
    // The entire point of the change: if the request only opened at release, the
    // upload would sit on the wait the user feels. Reaching `waitUntilEntered()`
    // at all is the assertion — the transcriber was called while the session is
    // still recording, and nothing has been released, stopped, or awaited.
    let probe = UploadProbe(transcript: "Hello world.")
    let session = makeUploadSession(probe)

    await session.press()
    #expect(await session.phase == .recording)
    await probe.waitUntilEntered()
  }

  @Test("the frame feed ends at release, which is what completes the body")
  func framesEndAtRelease() async throws {
    let probe = UploadProbe(transcript: "Hello world.")
    let session = makeUploadSession(probe)

    await session.press()
    await probe.waitUntilEntered()
    // The producer is parked on the feed: the recording is still open, so the
    // config part cannot have been written yet.
    #expect(probe.framesFinished == false)

    await session.release()
    await session.waitForIdle()

    // Release ended the feed, which is what lets the request complete.
    #expect(probe.framesFinished)
    #expect(await session.phase == .pasted)
  }

  @Test("a cancel while recording abandons the in-flight request")
  func cancelWhileRecordingAbandonsUpload() async throws {
    let probe = UploadProbe(transcript: "Hello world.")
    let injector = StubInjector()
    let session = makeUploadSession(probe, injector: injector)

    await session.press()
    await probe.waitUntilEntered()
    await session.cancel()
    await session.waitForIdle()

    #expect(await session.phase == .cancelled)
    // The request was cancelled, not completed: nothing was pasted, and the
    // transcript the probe would have returned never arrived.
    #expect(await injector.inserted.isEmpty)
    #expect(probe.completions == 0)
  }

  @Test("a cancel during transcribing cancels the request, not just the wait")
  func cancelDuringTranscribingCancelsUpload() async throws {
    // The window after release and before the response: the feed has ended and
    // the request is waiting on inference. Cancelling the pipeline only abandons
    // the *wait* — awaiting a `Task`'s value is not cancellation-aware — so the
    // request has to be cancelled by name or it runs to completion and
    // transcribes a dictation the user dismissed.
    let probe = UploadProbe(transcript: "Hello world.", holdsBeforeReturning: true)
    let session = makeUploadSession(probe)

    await session.press()
    await session.release()
    await probe.waitUntilHolding()
    #expect(await session.phase == .transcribing)

    await session.cancel()
    #expect(await session.phase == .cancelled)
    probe.allowToFinish()
    await session.awaitPipeline()

    #expect(probe.sawCancellation)
  }

  @Test("a too-short clip abandons the request instead of completing it")
  func tooShortClipAbandonsUpload() async throws {
    let mic = StubMicCapture()
    // Below `minPCMBytes` — an accidental tap. The request is already open and
    // carrying those bytes, so the guard has to abandon it rather than let it
    // finish and earn a 400.
    await mic.setPCM(Data(count: 8))
    let probe = UploadProbe(transcript: "Hello world.")
    let injector = StubInjector()
    let session = makeUploadSession(probe, mic: mic, injector: injector)

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .idle)
    #expect(await injector.inserted.isEmpty)
    #expect(probe.completions == 0)
  }

  @Test("a request that fails before its config part still leaves the context resolved")
  func contextSurvivesAnEarlyRequestFailure() async throws {
    // The context used to be populated as a side effect of the request reaching
    // its config part — pulled out of the session by the body producer. A
    // request that failed earlier (an early 401, a torn-down pipe) therefore
    // left the paste separator and the developer-mode error log believing the
    // dictation had no focused field at all. Now the release path resolves and
    // pushes it, so the failure is logged with what was actually captured.
    let log = RecordedLog()
    let session = DictationSession(
      mic: StubMicCapture(), transcriber: FailsBeforeContext(), injector: StubInjector(),
      keyTermsProvider: { [] },
      seams: testSeams(
        field: FocusCapture.FocusedFieldContext(
          priorText: "Dear Sam,", selectedText: nil, windowTitle: nil, fieldLabel: nil),
        log: log))

    await session.press()
    await session.release()
    await session.waitForIdle()

    let failure = try #require(log.failures.first)
    #expect(failure.context?.priorText == "Dear Sam,")
  }

  // MARK: - The body pipe

  @Test("the body pipe delivers every chunk, in order")
  func pipeDeliversChunksInOrder() async throws {
    let body = try ChunkedRequestBody()
    let reader = readAll(from: body)

    try await body.drain(.chunks(Data("first".utf8), Data("second".utf8), Data("third".utf8)))

    #expect(await reader.value == Data("firstsecondthird".utf8))
  }

  @Test("a producer failure surfaces rather than truncating the body silently")
  func producerFailurePropagates() async throws {
    let body = try ChunkedRequestBody()
    let reader = readAll(from: body)

    // Stands in for the `config` part failing to encode: the body can no longer
    // be completed, and the server would only report a generic 400.
    await #expect(throws: ChunkedUploadError.self) {
      try await body.drain(
        .chunks(Data("partial".utf8), failingWith: ChunkedUploadError.uploadNeverStarted))
    }
    _ = await reader.value
  }

  @Test("a reader that goes away fails the write instead of dropping audio")
  func closedReaderFailsTheWrite() async throws {
    let body = try ChunkedRequestBody()
    // Stands in for the transport abandoning the body — an early 401, or a
    // replay it asked for and was refused. The pipe can then stop accepting
    // bytes without ever reporting itself writable, so this has to fail rather
    // than poll forever or silently discard the rest of the recording.
    body.input.open()
    body.input.close()

    await #expect(throws: (any Error).self) {
      try await body.drain(.chunks(Data(count: 128 * 1024)))
    }
  }

  @Test("cancelling the upload stops the writer instead of parking on a full pipe")
  func cancellationUnblocksTheWriter() async throws {
    let body = try ChunkedRequestBody()
    // Nobody ever reads, so the pipe fills and the writer lands in its
    // backpressure loop. Cancellation is what has to get it out — `send` relies
    // on exactly this when the response arrives before the body is done.
    let writer = Task { try await body.drain(.chunks(Data(count: 512 * 1024))) }
    // Let it reach the loop before cancelling, so this exercises the wait rather
    // than the pre-flight `checkCancellation`.
    try await Task.sleep(for: .milliseconds(50))
    writer.cancel()

    await #expect(throws: CancellationError.self) { try await writer.value }
  }

  @Test("an early failure response outranks the torn-down pipe it causes")
  func earlyResponseWinsOverTheWriterError() async throws {
    // Authorization resolves concurrently with the upload, so a 401 can land
    // while the body is still being written — and writing then fails, because
    // the transport has torn the pipe down. The user has to see the status that
    // explains the failure, not "the upload connection closed". The body here is
    // far larger than the pipe, so the writer is certainly mid-write.
    let (data, response) = try await ChunkedRequestBody.send(
      URLRequest(url: URL(staticString: "https://example.invalid")),
      body: .chunks(Data(count: 512 * 1024)),
      delegate: nil
    ) { request, _ in
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil))
      return (Data(#"{"detail":"Invalid API key"}"#.utf8), response)
    }

    #expect((response as? HTTPURLResponse)?.statusCode == 401)
    #expect(!data.isEmpty)
  }

  @Test("URLSession is refused a second copy of the body, never handed an empty one")
  func replayIsRefused() async {
    // One of the three no-fallback guarantees. URLSession asks for a fresh body
    // stream whenever it has to send the request again — an auth challenge, a
    // 307, a connection retry it handles internally. A recording that has
    // already been streamed is gone, so the honest answer is nil, which fails
    // the request. Handing back anything else would re-send the dictation with
    // no audio in it and return a blank transcript.
    let delegate = DictationUploadDelegate()
    // Never resumed — the delegate ignores both arguments, so an idle task is
    // enough to exercise the contract without touching the network.
    let task = URLSession.shared.dataTask(with: URL(staticString: "https://example.invalid"))

    let replacement = await delegate.urlSession(.shared, needNewBodyStreamForTask: task)

    #expect(replacement == nil)
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
}

// MARK: - Fixtures

extension ChunkedUploadTests {
  /// A session wired to `probe`, with the doubles a chunked-upload test needs
  /// and nothing else. `makeSession` hard-codes `StubTranscriber`, which cannot
  /// report *when* it was called.
  private func makeUploadSession(
    _ probe: UploadProbe, mic: StubMicCapture = StubMicCapture(),
    injector: StubInjector = StubInjector()
  ) -> DictationSession {
    DictationSession(
      mic: mic, transcriber: probe, injector: injector,
      keyTermsProvider: { [] }, seams: .offline)
  }

  /// Stands in for the transport: owns the pipe's read end and drains it until
  /// the writer closes, which is what marks the body complete.
  private func readAll(from body: ChunkedRequestBody) -> Task<Data, Never> {
    Task.detached {
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
  }
}

/// Transcriber double that fails without ever reading the context channel — an
/// authorization failure that lands before the body is finished.
private struct FailsBeforeContext: TranscriberProtocol {
  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int, context: AsyncStream<TranscriptionContext?>
  ) async throws -> String {
    for await _ in frames {}
    throw AssemblyAIError.http(status: 401, message: "Invalid API key")
  }
}

/// Transcriber double that reports *when* it was called and, optionally, parks
/// after the feed ends — the two facts the chunked upload turns on and that a
/// return-value-only stub cannot show.
///
/// One type rather than two: "parks on entry" and "parks after resolving" are
/// the same double with the hold in a different place.
private final class UploadProbe: TranscriberProtocol, Sendable {
  private let transcript: String
  /// Opened the moment `transcribe` is entered, so a test can wait for the
  /// request to be in flight without polling a phase that never changes. A bare
  /// `AsyncGate`, not `Gate`: the probe must *not* block on entry — it parks on
  /// the frame feed instead, which is where the production producer waits.
  private let entered = AsyncGate()
  /// Where a real request waits for inference. Only armed when the test needs to
  /// land something while the session is `.transcribing`.
  private let holding: Gate?
  private let framesDone = ValueBox(false)
  private let cancelled = ValueBox(false)
  private let completed = ValueBox(0)

  init(transcript: String, holdsBeforeReturning: Bool = false) {
    self.transcript = transcript
    holding = holdsBeforeReturning ? Gate() : nil
  }

  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int, context: AsyncStream<TranscriptionContext?>
  ) async throws -> String {
    entered.open()
    // Drain the feed first, then take the context: that is the production order
    // (the config part is written after the last frame), and a probe that read
    // the context early would hide a session that stopped feeding the stream.
    for await _ in frames {}
    framesDone.value = true
    for await _ in context { break }
    // A channel that finished without a value means the dictation was
    // abandoned, and the real transcriber stops here rather than writing a
    // config part for it — see `TranscriberProtocol.transcribe`. A probe that
    // sailed on would report a completion the request never made.
    try Task.checkCancellation()
    if let holding {
      await holding.enter()
      // Sampled after the gate so the test controls when it is read; a real
      // request would have been torn down by the cancellation itself.
      cancelled.value = Task.isCancelled
    }
    completed.value += 1
    return transcript
  }

  func waitUntilEntered() async { await entered.wait() }
  func waitUntilHolding() async { await holding?.waitUntilEntered() }
  func allowToFinish() { holding?.allowToFinish() }

  var framesFinished: Bool { framesDone.value }
  var sawCancellation: Bool { cancelled.value }
  var completions: Int { completed.value }
}
