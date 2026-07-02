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

    // Bounded drain (a regression must fail, never hang the suite).
    for _ in 0..<1000 where await session.phase != .pasted { await Task.yield() }
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

    // Bounded drain (a regression must fail, never hang the suite).
    for _ in 0..<1000 where await session.phase != .cancelled { await Task.yield() }
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

    // Bounded drain (a regression must fail, never hang the suite).
    for _ in 0..<1000 where await session.phase != .cancelled { await Task.yield() }
    #expect(await session.phase == .cancelled)
    #expect(await mic.stopCalls == 1)
    #expect(await injector.inserted.isEmpty)
  }
}

/// Mic stub whose `start()` blocks until the test releases it, so `release()` can
/// be landed deterministically while `press()` is suspended inside `mic.start()`.
private actor GatedMicCapture: MicCaptureProtocol {
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private var startEntered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishGate: CheckedContinuation<Void, Never>?
  private var finished = false

  nonisolated func start() async throws { await enter() }

  private func enter() async {
    startCalls += 1
    startEntered = true
    for waiter in enteredWaiters { waiter.resume() }
    enteredWaiters.removeAll()
    if finished { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in finishGate = c }
  }

  func waitUntilStartEntered() async {
    if startEntered { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      enteredWaiters.append(c)
    }
  }

  func allowStartToFinish() {
    finished = true
    finishGate?.resume()
    finishGate = nil
  }

  nonisolated func stop() async throws -> [Float] {
    await incStop()
    // Above SyncSTTLimits.minSamples so the transcript isn't dropped by the
    // too-short guard — this suite exercises the press/release race, not it.
    return Array(repeating: 0, count: SyncSTTLimits.minSamples * 2)
  }

  private func incStop() { stopCalls += 1 }
}
