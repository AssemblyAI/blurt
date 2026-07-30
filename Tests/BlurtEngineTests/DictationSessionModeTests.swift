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
