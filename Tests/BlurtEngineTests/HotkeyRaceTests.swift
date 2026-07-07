import Foundation
import Testing

@testable import BlurtEngine

/// Fast-tap sequencing in the hold-to-dictate hotkey path. `press()` only
/// reaches `.recording` after awaiting `mic.start()`, and a fast tap lands its
/// `release()`/`cancel()` while the press is still inside that call. The
/// session's serial command queue must run the follow-up *after* the press —
/// honoring it against the freshly started recording — rather than dropping it
/// (which would strand the session in `.recording` until the ~115 s
/// auto-release fires).
@Suite("Hotkey press/release races", .timeLimit(.minutes(1)))
struct HotkeyRaceTests {

  @Test("release during mic.start is honored, not dropped")
  func releaseDuringStartIsHonored() async throws {
    let mic = GatedMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    let pressed = Task { await session.press() }
    await mic.waitUntilStartEntered()  // press() is now suspended inside mic.start()
    // Fast tap: the release arrives before .recording is set. It queues behind
    // the in-flight press (awaiting it inline would deadlock against the gate).
    let released = Task { await session.release() }
    await mic.allowStartToFinish()
    await pressed.value
    await released.value

    #expect(await mic.stopCalls == 1)  // release honored, not silently dropped

    await session.awaitPipeline()  // the honored release spawned the pipeline; join it
    #expect(await session.phase == .pasted)
    #expect(await injector.inserted == ["hi"])
  }

  @Test("cancel during mic.start is honored, not dropped")
  func cancelDuringStartIsHonored() async throws {
    let mic = GatedMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    let pressed = Task { await session.press() }
    await mic.waitUntilStartEntered()  // press() is now suspended inside mic.start()
    // Fast tap: the cancel arrives before .recording is set. It queues behind
    // the in-flight press and ends the freshly started recording.
    let cancelled = Task { await session.cancel() }
    await mic.allowStartToFinish()
    await pressed.value
    await cancelled.value

    #expect(await mic.stopCalls == 1)  // cancel honored and stops mic

    // Both the press and the queued cancel have run to completion (awaited via
    // their `.value` above), so the phase is settled — no drain needed.
    #expect(await session.phase == .cancelled)
    #expect(await injector.inserted.isEmpty)
  }

  /// A key repeat / double event: the serial command queue runs the second
  /// press after the first, where the non-terminal `.recording` phase drops it
  /// — the mic must never be started twice.
  @Test("a second press during mic.start is dropped, not double-started")
  func secondPressDuringStartIsDropped() async throws {
    let mic = GatedMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    let pressed = Task { await session.press() }
    await mic.waitUntilStartEntered()  // first press() is suspended inside mic.start()
    // Queues behind the in-flight press (awaiting it inline would deadlock
    // against the gate) and must be dropped when its turn comes.
    let secondPress = Task { await session.press() }
    await mic.allowStartToFinish()
    await pressed.value
    await secondPress.value

    #expect(await mic.startCalls == 1)
    #expect(await session.phase == .recording)

    // End the live recording so its auto-release timer doesn't outlive the test.
    await session.cancel()
  }

  /// Release and cancel both racing in during `mic.start()`: the documented
  /// precedence is that the cancel request overrides the queued release, so the
  /// tap ends `.cancelled` with nothing transcribed — not a full
  /// transcribe→inject run.
  @Test("cancel overrides a pending release during mic.start")
  func cancelOverridesPendingReleaseDuringStart() async throws {
    let mic = GatedMicCapture()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    let pressed = Task { await session.press() }
    await mic.waitUntilStartEntered()
    // Both queue behind the in-flight press. The drain lets cancel() record its
    // request before the queued release runs, so the release deterministically
    // consumes it after mic.stop() and spawns no pipeline.
    let released = Task { await session.release() }
    let cancelled = Task { await session.cancel() }
    for _ in 0..<1000 { await Task.yield() }
    await mic.allowStartToFinish()
    await pressed.value
    await released.value
    await cancelled.value

    // All three commands have run to completion (awaited via `.value`), so the
    // phase is settled at the cancel's claim — no drain needed.
    #expect(await session.phase == .cancelled)
    #expect(await mic.stopCalls == 1)
    #expect(await injector.inserted.isEmpty)
  }
}

/// Mic stub whose `start()` blocks until the test releases it, so `release()` can
/// be landed deterministically while `press()` is suspended inside `mic.start()`.
/// The entry/finish choreography lives in the shared `Gate`.
private actor GatedMicCapture: MicCaptureProtocol {
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private let gate = Gate()

  func start() async throws {
    startCalls += 1
    await gate.enter()
  }

  func waitUntilStartEntered() async { await gate.waitUntilEntered() }
  func allowStartToFinish() async { await gate.allowToFinish() }

  func stop() async throws -> [Float] {
    stopCalls += 1
    // Above SyncSTTLimits.minSamples so the transcript isn't dropped by the
    // too-short guard — this suite exercises the press/release race, not it.
    return Array(repeating: 0, count: SyncSTTLimits.minSamples * 2)
  }
}
