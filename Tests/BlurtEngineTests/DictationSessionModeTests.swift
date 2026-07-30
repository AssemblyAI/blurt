import Foundation
import Testing

@testable import BlurtEngine

/// The dictation mode chosen at press time must reach the transcriber's
/// `cleanup` flag unchanged, so the raw key gets a verbatim request and the
/// cleaned key an LLM-rewrite request. Pins that threading through the pipeline.
@Suite("DictationSession mode", .timeLimit(.minutes(1)))
struct DictationSessionModeTests {
  @Test(
    "press(mode:) threads the cleanup flag to the transcriber",
    arguments: [(DictationMode.raw, false), (DictationMode.cleaned, true)])
  func modeThreadsCleanup(mode: DictationMode, expectedCleanup: Bool) async {
    let transcriber = ModeRecordingTranscriber()
    let session = DictationSession(
      mic: StubMicCapture(), transcriber: transcriber, injector: StubInjector())

    await session.press(mode: mode)
    await session.release()
    await session.awaitPipeline()

    #expect(await transcriber.lastCleanup == expectedCleanup)
  }

  @Test("a mode-less press defaults to the cleaned (rewrite) request")
  func defaultPressCleansUp() async {
    let transcriber = ModeRecordingTranscriber()
    let session = DictationSession(
      mic: StubMicCapture(), transcriber: transcriber, injector: StubInjector())

    await session.press()
    await session.release()
    await session.awaitPipeline()

    #expect(await transcriber.lastCleanup == true)
  }

  @Test("a press the terminal-phase guard rejects doesn't clobber the in-flight mode")
  func rejectedPressLeavesInFlightModeUntouched() async {
    // The reachable race the guard-ordering fix closes: after a release the gate
    // is idle, so the *other* mode's key can fire a fresh `.start` while the
    // prior dictation is still `.transcribing`. That press is rejected by
    // `guard phase.isTerminal`, but must not overwrite `activeMode` first — the
    // in-flight run reads it after its context-wait.
    let transcriber = GatedModeTranscriber()
    let session = DictationSession(
      mic: StubMicCapture(), transcriber: transcriber, injector: StubInjector())

    await session.press(mode: .raw)
    await session.release()
    // Park deterministically inside the (gated) transcribe, so the actor is free
    // and the injected press below runs to its guard before the pipeline resumes.
    await transcriber.waitUntilStarted()

    // The other key taps mid-transcribe: `.transcribing` is non-terminal, so the
    // guard rejects it. With the bug it would first set `activeMode = .cleaned`.
    await session.press(mode: .cleaned)
    #expect(await session.activeMode == .raw)

    await transcriber.allowToFinish()
    await session.awaitPipeline()
    // The delivered dictation transcribed as raw, never re-tagged to cleaned.
    #expect(await transcriber.recordedCleanup == false)
  }
}

/// A transcriber that parks inside `transcribe` until released, so a test can
/// land a second press while the first dictation is deterministically in-flight.
/// Records the `cleanup` flag it was actually called with.
private actor GatedModeTranscriber: TranscriberProtocol {
  private(set) var recordedCleanup: Bool?
  private var startedFlag = false
  private var startedWaiter: CheckedContinuation<Void, Never>?
  private var releaseFlag = false
  private var releaseWaiter: CheckedContinuation<Void, Never>?

  func transcribe(
    pcm: Data, sampleRate: Int, context: TranscriptionContext?, cleanup: Bool
  ) async throws -> String {
    recordedCleanup = cleanup
    startedFlag = true
    startedWaiter?.resume()
    startedWaiter = nil
    if !releaseFlag {
      await withCheckedContinuation { releaseWaiter = $0 }
    }
    return "Hello world."
  }

  func waitUntilStarted() async {
    if startedFlag { return }
    await withCheckedContinuation { startedWaiter = $0 }
  }

  func allowToFinish() {
    releaseFlag = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}

/// Records the `cleanup` flag of the most recent request so a test can assert
/// the mode reached the wire boundary.
private actor ModeRecordingTranscriber: TranscriberProtocol {
  private(set) var lastCleanup: Bool?

  func transcribe(
    pcm: Data, sampleRate: Int, context: TranscriptionContext?, cleanup: Bool
  ) async throws -> String {
    lastCleanup = cleanup
    return "Hello world."
  }
}
