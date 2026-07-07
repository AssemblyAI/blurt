import Foundation
import Testing

@testable import BlurtEngine

/// Races in `DictationSession.release()`. `release()` has two real triggers — the
/// manual key-up and the auto-release timer — and it suspends inside
/// `await mic.stop()`. `performRelease` claims `.transcribing` *before* that
/// suspension (both for the stop cue's sake — see the test below — and so a
/// second release interleaving during the stop fails the `.recording` guard
/// instead of double-stopping the mic and injecting the transcript twice).
/// These tests pin both halves of that ordering.
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

    // Release #1 suspends inside mic.stop(); release #2 then interleaves while
    // that stop is parked — it must fail the .recording guard (the phase is
    // already .transcribing) rather than run the pipeline a second time.
    let first = Task { await session.release() }
    await mic.waitUntilStopEntered()
    let second = Task { await session.release() }
    // Let a (buggy) release #2 reach a second mic.stop() before we let stop
    // finish; bounded so a regression fails the assertion, not the suite clock.
    for _ in 0..<1000 where await mic.stopCalls < 2 { await Task.yield() }
    await mic.allowStopToFinish()
    await first.value
    await second.value

    // The pipeline (transcribe → inject) runs asynchronously after both releases
    // return; wait on the phase stream for its terminal phase rather than a
    // yield-count budget, which drains this task but not the pipeline's
    // cross-actor/detached hops and so flaked out before `.pasted` under load.
    await session.waitForIdle()
    #expect(await mic.stopCalls == 1)
    #expect(await injector.inserted == ["hi"])
    #expect(await session.phase == .pasted)
  }

  @Test("release claims .transcribing before mic.stop completes")
  func transcribingClaimedBeforeMicStopReturns() async throws {
    let mic = GatedStopMic()
    let stt = StubTranscriber(mode: .transcript("hi"))
    let injector = StubInjector()
    let session = DictationSession(mic: mic, transcriber: stt, injector: injector)

    await session.press()
    let release = Task { await session.release() }
    await mic.waitUntilStopEntered()

    // The stop chime and the pill's "Transcribing…" ride this transition — it
    // must fire at key-up, not after the recorded audio has been read back.
    #expect(await session.phase == .transcribing)

    await mic.allowStopToFinish()
    await release.value
    await session.waitForIdle()
    #expect(await session.phase == .pasted)
    #expect(await injector.inserted == ["hi"])
  }
}
