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
    for _ in 0..<1000 where await injector.inserted.isEmpty == false { break }
    // Give the pipeline task a chance to (incorrectly) run inject before asserting.
    for _ in 0..<1000 { await Task.yield() }

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
    for _ in 0..<1000 { await Task.yield() }

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
      for _ in 0..<1000 { await Task.yield() }

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

    // Phase is still .recording here but `isStopping` bars the direct path —
    // this cancel must be deferred and honored, not silently dropped (a drop
    // would paste the transcript the user just cancelled).
    await session.cancel()
    await mic.allowStopToFinish()
    await releaseTask.value
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

    await session.cancel()
    await mic.allowStopToFinish()
    await releaseTask.value

    // The user asked for nothing to happen — the cancel claims the phase
    // rather than the stop failure repainting it as a red .failed.
    #expect(await session.phase == .cancelled)
    #expect(await injector.inserted.isEmpty)
  }

  @Test("cancel tears down the armed auto-release timer; the session stays .cancelled")
  func cancelTearsDownAutoRelease() async throws {
    let mic = StubMicCapture()
    // Would inject "Timed out text." if the auto-release timer ever fired release().
    let stt = StubTranscriber(mode: .transcript("Timed out text."))
    let injector = StubInjector()
    // A short cap so a *live* timer would fire well within the wait below — the
    // test proves cancel cancelled it, not that the timer simply hasn't elapsed.
    let session = DictationSession(
      mic: mic, transcriber: stt, injector: injector, maxRecordingSeconds: 0.05)

    await session.press()
    #expect(await session.phase == .recording)
    await session.cancel()
    #expect(await session.phase == .cancelled)

    // Wait past the auto-release deadline. A timer that survived the cancel would
    // fire releaseIfRecording → release → transcribe → inject and flip the phase.
    try await Task.sleep(for: .milliseconds(150))
    for _ in 0..<1000 { await Task.yield() }

    #expect(await session.phase == .cancelled)
    #expect(await injector.inserted.isEmpty)
    // Only the cancel's own stop ran — the auto-release never stopped the mic again.
    #expect(await mic.stopCalls == 1)
  }
}

/// Mic stub that signals when `stop()` is entered and then blocks until
/// released, so a `cancel()` can be landed deterministically while `release()`
/// is suspended inside `mic.stop()` — the window where the phase is still
/// `.recording` but `isStopping` bars the direct cancel path.
private actor GatedStopMic: MicCaptureProtocol {
  private let stopError: (any Error & Sendable)?
  private var entered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var finished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  init(stopError: (any Error & Sendable)? = nil) { self.stopError = stopError }

  func start() async throws {}

  func stop() async throws -> [Float] {
    entered = true
    for waiter in enteredWaiters { waiter.resume() }
    enteredWaiters.removeAll()
    if !finished {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        finishWaiters.append(c)
      }
    }
    if let stopError { throw stopError }
    return Array(repeating: 0, count: SyncSTTLimits.minSamples * 2)
  }

  func waitUntilStopEntered() async {
    if entered { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      enteredWaiters.append(c)
    }
  }

  func allowStopToFinish() {
    finished = true
    for waiter in finishWaiters { waiter.resume() }
    finishWaiters.removeAll()
  }
}

/// Transcriber stub that signals when `transcribe` is entered and then blocks
/// until released, so a `cancel()` can be landed deterministically while the
/// session is suspended in `.transcribing`.
private actor GatedTranscriber: TranscriberProtocol {
  private let text: String
  /// When true, a release that arrives after the task was cancelled throws
  /// `URLError(.cancelled)` — mimicking the real URLSession-backed transcriber,
  /// whose in-flight request is torn down by task cancellation.
  private let throwsWhenCancelled: Bool
  private var started = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var finished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  init(text: String, throwsWhenCancelled: Bool = false) {
    self.text = text
    self.throwsWhenCancelled = throwsWhenCancelled
  }

  nonisolated func transcribe(samples: [Float], sampleRate: Int, context: TranscriptionContext?)
    async throws -> String
  {
    await enter()
    if throwsWhenCancelled && Task.isCancelled { throw URLError(.cancelled) }
    return text
  }

  private func enter() async {
    started = true
    for waiter in startedWaiters { waiter.resume() }
    startedWaiters.removeAll()
    if !finished {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        finishWaiters.append(c)
      }
    }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      startedWaiters.append(c)
    }
  }

  func allowToFinish() {
    finished = true
    for waiter in finishWaiters { waiter.resume() }
    finishWaiters.removeAll()
  }
}

/// Injector stub that honors task cancellation (like the real `KeyInjector`) and
/// blocks inside `insert` until released, so a `cancel()` can be landed while the
/// session is suspended in `.injecting`.
private actor GatedInjector: InjectorProtocol {
  private var entered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var finished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []
  /// Fired each time a paste is actually recorded — lets a test assert, via
  /// `confirmation(expectedCount: 0)`, that a cancelled injection records nothing.
  private let onRecord: @Sendable () -> Void

  init(onRecord: @escaping @Sendable () -> Void = {}) { self.onRecord = onRecord }

  nonisolated func setTargetApp(_ app: NSRunningApplication?) async {}

  nonisolated func insert(_ text: String, after priorText: String?) async throws {
    try await enter()
    try Task.checkCancellation()
    await recordPaste()
  }

  private func enter() async throws {
    entered = true
    for waiter in enteredWaiters { waiter.resume() }
    enteredWaiters.removeAll()
    if !finished {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        finishWaiters.append(c)
      }
    }
  }

  private func recordPaste() { onRecord() }

  func waitUntilInsertEntered() async {
    if entered { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      enteredWaiters.append(c)
    }
  }

  func allowInsertToFinish() {
    finished = true
    for waiter in finishWaiters { waiter.resume() }
    finishWaiters.removeAll()
  }
}
