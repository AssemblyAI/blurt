import AppKit
import Foundation
import Testing

@testable import BlurtEngine

/// Cancel arriving after recording has already stopped — i.e. while the pipeline
/// is in `.transcribing` or `.injecting`. The transcribe→inject work runs in a
/// detached task spawned by `release()`; a `cancel()` (DictationKeyGate can emit
/// one) must tear that task down so the transcript is never pasted into the
/// focused app, and must win the phase race so the result isn't overwritten back
/// to `.idle`.
///
/// `.timeLimit` guards the actor/task choreography: a hang fails fast rather than
/// stalling the run until the job times out (1 min is the trait minimum; these
/// finish in milliseconds).
@Suite("DictationSession cancel races", .timeLimit(.minutes(1)))
struct CancelRaceTests {

  @Test("cancel during transcribing discards the transcript and ends .cancelled")
  func cancelDuringTranscribingDiscards() async throws {
    let mic = StubMicCapture()
    let stt = GatedTranscriber(text: "Hello world.")
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    await session.release()  // -> .transcribing, spawns the pipeline task
    await stt.waitUntilStarted()  // transcribe is now suspended awaiting release
    #expect(await session.phase == .transcribing)

    await session.cancel()
    #expect(await session.phase == .cancelled)

    // Let transcribe finish: the cancelled pipeline must NOT inject, and must not
    // overwrite the .cancelled phase.
    await stt.allowToFinish()
    // Join the cancelled pipeline's teardown: it resumes transcribe, sees the
    // cancellation, and must return without injecting or repainting the phase.
    await session.awaitPipeline()

    #expect(await injector.inserted.isEmpty)
    #expect(await session.phase == .cancelled)
  }

  @Test("cancel during transcribing with a throwing transcriber stays .cancelled")
  func cancelDuringTranscribingThrowingStaysCancelled() async throws {
    let mic = StubMicCapture()
    // Mimics the real transcriber: the cancelled URLSession request throws
    // URLError(.cancelled), which must not be repainted as a red .failed (or
    // reported as a fault) over the .cancelled the cancel() already claimed.
    let stt = GatedTranscriber(text: "Hello world.", throwsWhenCancelled: true)
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    await session.release()
    await stt.waitUntilStarted()
    await session.cancel()
    #expect(await session.phase == .cancelled)

    await stt.allowToFinish()
    await session.awaitPipeline()

    #expect(await session.phase == .cancelled)
    #expect(await injector.inserted.isEmpty)
  }

  @Test("cancel during injecting discards the transcript and ends .cancelled")
  func cancelDuringInjectingDiscards() async throws {
    // `expectedCount: 0`: the paste must never be recorded. This is event-driven
    // (the injector fires the confirmation only if it actually records) rather
    // than inferred from an empty array after the fact.
    await confirmation("cancelled injection records no paste", expectedCount: 0) { pasted in
      let mic = StubMicCapture()
      let stt = StubTranscriber(mode: .transcript("Hello world."))
      let injector = GatedInjector(onRecord: { pasted() })
      let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

      await session.press()
      await session.release()
      await injector.waitUntilInsertEntered()  // pipeline is inside injector.insert
      #expect(await session.phase == .injecting)

      await session.cancel()
      #expect(await session.phase == .cancelled)

      await injector.allowInsertToFinish()
      await session.awaitPipeline()

      // The phase stays .cancelled rather than being overwritten to .idle.
      #expect(await session.phase == .cancelled)
    }
  }

  @Test("cancel while release is stopping the mic discards the recording")
  func cancelDuringMicStopDiscards() async throws {
    let mic = GatedStopMic()
    let stt = StubTranscriber(mode: .transcript("Hello world."))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    #expect(await session.phase == .recording)
    let releaseTask = Task { await session.release() }
    await mic.waitUntilStopEntered()  // release is now suspended inside mic.stop()

    // cancel() records its request the moment it enters the session (the actor
    // is free — the release is parked inside the gated mic.stop), then queues
    // its turn behind the release; awaiting it inline here would deadlock
    // against the gate. The drain gives cancel() that entry deterministically.
    let cancelTask = Task { await session.cancel() }
    for _ in 0..<1000 { await Task.yield() }
    await mic.allowStopToFinish()
    // The release must consume the cancel request after mic.stop() returns and
    // spawn no pipeline — the transcript the user cancelled is never pasted.
    await releaseTask.value
    await cancelTask.value
    for _ in 0..<1000 { await Task.yield() }

    #expect(await session.phase == .cancelled)
    #expect(await injector.inserted.isEmpty)
  }

  @Test("cancel while release's mic.stop fails still wins over the audio error")
  func cancelDuringFailingMicStopWinsOverError() async throws {
    let mic = GatedStopMic(stopError: URLError(.unknown))
    let stt = StubTranscriber(mode: .transcript("Hello world."))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    let releaseTask = Task { await session.release() }
    await mic.waitUntilStopEntered()

    // See cancelDuringMicStopDiscards for the Task + drain choreography.
    let cancelTask = Task { await session.cancel() }
    for _ in 0..<1000 { await Task.yield() }
    await mic.allowStopToFinish()
    await releaseTask.value
    await cancelTask.value

    // The user asked for nothing to happen — the cancel claims the phase
    // rather than the stop failure repainting it as a red .failed.
    #expect(await session.phase == .cancelled)
    #expect(await injector.inserted.isEmpty)
  }

  @Test("cancelRecording during transcribing leaves the pipeline alone")
  func cancelRecordingDoesNotTearDownTranscribing() async throws {
    let mic = StubMicCapture()
    let stt = GatedTranscriber(text: "Hello world.")
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    await session.release()  // -> .transcribing, spawns the pipeline task
    await stt.waitUntilStarted()
    #expect(await session.phase == .transcribing)

    // The narrow recovery cancel (tap disabled / trigger rebound): the capture
    // already ended legitimately, so the in-flight transcript must survive —
    // unlike a user-intent cancel(), which tears it down.
    await session.cancelRecording()
    #expect(await session.phase == .transcribing)

    await stt.allowToFinish()
    await session.awaitPipeline()

    #expect(await session.phase == .pasted)
    #expect(await injector.inserted == ["Hello world."])
  }

  @Test("cancelRecording during recording cancels like cancel()")
  func cancelRecordingCancelsLiveRecording() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Hello world."))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    #expect(await session.phase == .recording)
    await session.cancelRecording()
    #expect(await session.phase == .cancelled)
    #expect(await mic.stopCalls == 1)
    #expect(await injector.inserted.isEmpty)
  }

  @Test("cancel landing in insert's non-cancellable tail stays .cancelled, not .pasted")
  func cancelDuringInjectingTailStaysCancelled() async throws {
    let mic = StubMicCapture()
    let stt = StubTranscriber(mode: .transcript("Hello world."))
    // Models the real injector's final stretch (after its last cancellation
    // check, once the paste has landed): insert returns *normally* even though
    // the task was cancelled mid-flight.
    let injector = GatedInjector(honorsCancellation: false)
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    await session.release()
    await injector.waitUntilInsertEntered()
    #expect(await session.phase == .injecting)

    await session.cancel()
    #expect(await session.phase == .cancelled)

    // The paste completed anyway (it was already irreversible), but the session
    // must not repaint the user's cancel as a successful .pasted.
    await injector.allowInsertToFinish()
    await session.awaitPipeline()
    #expect(await session.phase == .cancelled)
  }

  @Test("cancel tears down the armed auto-release timer; the session stays .cancelled")
  func cancelTearsDownAutoRelease() async throws {
    let mic = StubMicCapture()
    // Would inject "Timed out text." if the auto-release timer ever fired release().
    let stt = StubTranscriber(mode: .transcript("Timed out text."))
    let injector = StubInjector()
    // A controllable clock so the auto-release deadline can be crossed
    // deterministically — the test proves cancel cancelled the timer, not that
    // the timer simply hasn't elapsed in wall-clock time.
    let clock = TestClock()
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector, maxRecordingSeconds: 0.05, clock: clock)

    await session.press()
    #expect(await session.phase == .recording)
    await session.cancel()
    #expect(await session.phase == .cancelled)

    // Advance well past the auto-release deadline. A timer that survived the
    // cancel would enqueue a release → transcribe → inject and flip the phase;
    // the cancelled one has no sleeper left to wake.
    clock.advance(by: .seconds(1))
    await session.awaitPipeline()

    #expect(await session.phase == .cancelled)
    #expect(await injector.inserted.isEmpty)
    // Only the cancel's own stop ran — the auto-release never stopped the mic again.
    #expect(await mic.stopCalls == 1)
  }
}

/// Transcriber stub that signals when `transcribe` is entered and then blocks
/// until released, so a `cancel()` can be landed deterministically while the
/// session is suspended in `.transcribing`. Gate choreography lives in `Gate`.
private actor GatedTranscriber: TranscriberProtocol {
  private let text: String
  /// When true, a release that arrives after the task was cancelled throws
  /// `URLError(.cancelled)` — mimicking the real URLSession-backed transcriber,
  /// whose in-flight request is torn down by task cancellation.
  private let throwsWhenCancelled: Bool
  private let gate = Gate()

  init(text: String, throwsWhenCancelled: Bool = false) {
    self.text = text
    self.throwsWhenCancelled = throwsWhenCancelled
  }

  func transcribe(samples: [Float], sampleRate: Int, context: TranscriptionContext?)
    async throws -> String
  {
    await gate.enter()
    if throwsWhenCancelled && Task.isCancelled { throw URLError(.cancelled) }
    return text
  }

  func waitUntilStarted() async { await gate.waitUntilEntered() }
  func allowToFinish() async { await gate.allowToFinish() }
}

/// Injector stub that honors task cancellation (like the real `KeyInjector`) and
/// blocks inside `insert` until released, so a `cancel()` can be landed while the
/// session is suspended in `.injecting`. Gate choreography lives in `Gate`.
private actor GatedInjector: InjectorProtocol {
  /// Fired each time a paste is actually recorded — lets a test assert, via
  /// `confirmation(expectedCount: 0)`, that a cancelled injection records nothing.
  private let onRecord: @Sendable () -> Void

  /// When false, `insert` skips its cancellation check and returns normally on a
  /// cancelled task — modeling the real injector's final, non-cancellable
  /// stretch after its last `checkCancellation` (the paste already landed).
  private let honorsCancellation: Bool
  private let gate = Gate()

  init(honorsCancellation: Bool = true, onRecord: @escaping @Sendable () -> Void = {}) {
    self.honorsCancellation = honorsCancellation
    self.onRecord = onRecord
  }

  func setTargetApp(_ app: NSRunningApplication?) async {}

  func insert(_ text: String, after priorText: String?, windowTitle: String?) async throws {
    await gate.enter()
    if honorsCancellation { try Task.checkCancellation() }
    onRecord()
  }

  func waitUntilInsertEntered() async { await gate.waitUntilEntered() }
  func allowInsertToFinish() async { await gate.allowToFinish() }
}
