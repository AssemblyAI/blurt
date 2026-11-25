import Testing

@testable import BlurtEngine

/// The host's "something is in flight" can be a moment stale, so a cancel may
/// reach a session already at rest. It must change nothing there.
@Suite("DictationSession · stray cancel", .timeLimit(.minutes(1)))
struct DictationSessionStrayCancelTests {
  @Test("a cancel at rest leaves no standing request: the next press records")
  func cancelAtRestIsInert() async {
    let session = makeSession(transcriber: StubTranscriber(mode: .transcript("Hello world.")))
    await session.cancel()
    #expect(await session.phase == .idle)
    #expect(!session.cancelRequested)
    await session.press()
    #expect(await session.phase == .recording)
  }
}
