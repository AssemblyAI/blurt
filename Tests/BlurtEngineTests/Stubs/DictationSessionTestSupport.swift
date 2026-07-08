import Foundation

@testable import BlurtEngine

/// A `DictationSession` plus the stubs a test configures or asserts against
/// after driving the session (e.g. `mic.setStartError`, `injector.setError`).
/// The transcriber stub is deliberately absent: its behavior is fully
/// determined up front by `makeSession`'s `mode`, so no test needs it
/// afterwards.
struct SessionFixture {
  let session: DictationSession
  let mic: StubMicCapture
  let injector: StubInjector
}

/// Builds a `SessionFixture`, collapsing the four-line `mic`/`stt`/`injector`/
/// `session` setup the session suites otherwise repeat.
func makeSession(
  mode: StubTranscriber.Mode = .transcript("Hello world."),
  maxRecordingSeconds: Double = SyncSTTLimits.autoReleaseSeconds,
  onTranscriptDelivered: (@Sendable (String) -> Void)? = nil
) -> SessionFixture {
  let mic = StubMicCapture()
  let injector = StubInjector()
  let session = DictationSession(
    mic: mic, transcriber: StubTranscriber(mode: mode), injector: injector,
    maxRecordingSeconds: maxRecordingSeconds,
    onTranscriptDelivered: onTranscriptDelivered)
  return SessionFixture(session: session, mic: mic, injector: injector)
}

extension DictationSession {
  /// Completes when the session reaches a terminal phase (idle/failed). Lives in
  /// the test target rather than the engine because only tests await terminal
  /// states; the production app drives off `phaseStream()` directly.
  func waitForIdle() async {
    if phase.isTerminal { return }
    for await p in phaseStream() where p.isTerminal { return }
  }

  /// Joins the in-flight transcribe→inject task spawned by `release()` —
  /// including the early-return path a `cancel()` triggers — so a test can
  /// deterministically let it run to completion instead of spinning on
  /// `Task.yield()`. Nil when no pipeline is in flight (returns immediately).
  /// A test-target extension over the engine's internal `pipelineTask` (reached
  /// via `@testable`), mirroring `waitForIdle`: production never needs it.
  func awaitPipeline() async {
    await pipelineTask?.value
  }
}
