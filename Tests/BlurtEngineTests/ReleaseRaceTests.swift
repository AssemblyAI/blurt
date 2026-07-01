import Foundation
import Testing

@testable import BlurtEngine

/// Races in `DictationSession.release()`. `release()` has two real triggers — the
/// manual key-up and the auto-release timer — and there is an `await mic.stop()`
/// between its `phase == .recording` guard and the `setPhase(.transcribing)` that
/// closes the window. If a second release lands during that suspension (e.g. the
/// auto-release timer's continuation wins the scheduling race against a manual
/// key-up), both pass the guard and run the pipeline, double-stopping the mic and
/// injecting the transcript twice. These tests pin that window.
@Suite("DictationSession release races", .timeLimit(.minutes(1)))
struct ReleaseRaceTests {

  @Test("a second release during mic.stop is dropped, not run twice")
  func reentrantReleaseRunsPipelineOnce() async throws {
    let mic = GatedStopMic()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    #expect(await session.phase == .recording)

    // Release #1 suspends inside mic.stop(); release #2 then interleaves while the
    // session is still .recording (transcribing hasn't been set yet).
    let first = Task { await session.release() }
    await mic.waitUntilStopEntered()
    let second = Task { await session.release() }
    // Let release #2 reach its (buggy) second mic.stop() before we let stop finish;
    // bounded so a regression fails the assertion rather than hanging the suite.
    for _ in 0..<1000 where await mic.stopCalls < 2 { await Task.yield() }
    await mic.allowStopToFinish()
    await first.value
    await second.value

    for _ in 0..<1000 where await session.phase != .pasted { await Task.yield() }
    #expect(await mic.stopCalls == 1)
    #expect(await injector.inserted == ["hi"])
    #expect(await session.phase == .pasted)
  }
}

/// Mic stub whose `stop()` blocks until released, so a second `release()` can be
/// landed deterministically while the first is suspended inside `mic.stop()`.
/// Tolerates concurrent `stop()` calls (the bug under test triggers a second).
private actor GatedStopMic: MicCaptureProtocol {
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private var stopEntered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []
  private var finished = false

  nonisolated func start() async throws { await incStart() }
  private func incStart() { startCalls += 1 }

  nonisolated func stop() async throws -> [Float] { await enterStop() }

  private func enterStop() async -> [Float] {
    stopCalls += 1
    stopEntered = true
    for waiter in enteredWaiters { waiter.resume() }
    enteredWaiters.removeAll()
    if !finished {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        finishWaiters.append(c)
      }
    }
    // Above SyncSTTLimits.minSamples so the transcript isn't dropped by the
    // too-short guard — this suite exercises the release race, not it.
    return Array(repeating: 0, count: SyncSTTLimits.minSamples(sampleRate: SyncSTTLimits.sampleRate) * 2)
  }

  func waitUntilStopEntered() async {
    if stopEntered { return }
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
