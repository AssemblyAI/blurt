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
    let session = makeSession(transcriber: probe)

    await session.press()
    #expect(await session.phase == .recording)
    await probe.waitUntilEntered()
  }

  @Test("the frame feed ends at release, which is what completes the body")
  func framesEndAtRelease() async throws {
    let probe = UploadProbe(transcript: "Hello world.")
    let session = makeSession(transcriber: probe)

    await session.press()
    await probe.waitUntilEntered()
    // The producer is parked on the feed: the recording is still open, so the
    // body cannot have been closed yet. (It is no longer the `config` part that
    // is outstanding — that one leads the body now — but the closing boundary.)
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
    let session = makeSession(transcriber: probe, injector: injector)

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
    let session = makeSession(transcriber: probe)

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
    let session = makeSession(transcriber: probe, mic: mic, injector: injector)

    await session.press()
    await session.release()
    await session.waitForIdle()

    #expect(await session.phase == .idle)
    #expect(await injector.inserted.isEmpty)
    #expect(probe.completions == 0)
  }

  @Test("a cancel during the context wait stays cancelled, not repainted as a failure")
  func cancelDuringContextWaitStaysCancelled() async throws {
    // `setPhase` clears `upload` on any terminal phase, so a cancel landing
    // while the pipeline is waiting on the request leaves that task to resume,
    // find no handle, and — before this guard — repaint the user's own cancel as
    // a red failure with a developer-mode error entry. The context read blocks
    // for the whole test, which holds the *upload* inside its own context wait
    // (`startUpload`, not the release path, since `config` leads the body now)
    // and so holds the pipeline in that window deterministically.
    let log = RecordedLog()
    let (seams, release) = hungFieldSeams(log: log)
    let session = makeSession(transcriber: UploadProbe(transcript: "Hello world."), seams: seams)

    await session.press()
    await session.release()
    #expect(await session.phase == .transcribing)
    await session.cancel()
    #expect(await session.phase == .cancelled)

    release.signal()
    await session.awaitPipeline()

    // The user's cancel is what stands, and nothing is logged as broken.
    #expect(await session.phase == .cancelled)
    #expect(log.failures.isEmpty)
  }

  @Test("a request that fails without using the context still leaves it resolved")
  func contextSurvivesAnEarlyRequestFailure() async throws {
    // The context used to be populated as a side effect of the request reaching
    // its config part — pulled out of the session by the body producer. A
    // request that failed earlier (an early 401, a torn-down pipe) therefore
    // left the paste separator and the developer-mode error log believing the
    // dictation had no focused field at all. Now the release path resolves and
    // pushes it, so the failure is logged with what was actually captured.
    let log = RecordedLog()
    let session = makeSession(
      transcriber: FailsBeforeContext(),
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
}

// MARK: - Fixtures

/// Transcriber double that fails without ever using the context — an
/// authorization failure that lands before the body is finished. Still pins that
/// the session recorded the press-time context for the log: `startUpload` adopts
/// it before it opens the request, so a request that fails immediately cannot
/// take the context down with it.
private struct FailsBeforeContext: TranscriberProtocol {
  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
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
  private let completed = Counter()

  init(transcript: String, holdsBeforeReturning: Bool = false) {
    self.transcript = transcript
    holding = holdsBeforeReturning ? Gate() : nil
  }

  func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
  ) async throws -> String {
    entered.open()
    // The session has to keep feeding the stream for the request to complete,
    // and a probe that returned early would hide one that stopped. Spelled out
    // rather than using `drainUntilAbandoned`, because the flag has to be set
    // between the two halves: this probe reports *when* the feed ended, and a
    // cancelled run must not report a feed that did end as unfinished.
    for await _ in frames {}
    framesDone.value = true
    try Task.checkCancellation()
    if let holding {
      await holding.enter()
      // Sampled after the gate so the test controls when it is read; a real
      // request would have been torn down by the cancellation itself.
      cancelled.value = Task.isCancelled
    }
    _ = completed.next()
    return transcript
  }

  func waitUntilEntered() async { await entered.wait() }
  func waitUntilHolding() async { await holding?.waitUntilEntered() }
  func allowToFinish() { holding?.allowToFinish() }

  var framesFinished: Bool { framesDone.value }
  var sawCancellation: Bool { cancelled.value }
  var completions: Int { completed.value }
}
