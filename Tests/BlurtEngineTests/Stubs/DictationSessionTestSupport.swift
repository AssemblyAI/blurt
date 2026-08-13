import Foundation
import Synchronization

@testable import BlurtEngine

/// A `DictationSession` plus the doubles a test configures or asserts against
/// after driving it (e.g. `mic.setStartError`, `injector.setError`,
/// `transcriber.receivedContexts`, `log.failureNames`).
struct SessionFixture {
  let session: DictationSession
  let mic: StubMicCapture
  let transcriber: StubTranscriber
  let injector: StubInjector
  /// What the session logged. A recorder rather than `DictationLog`, so a suite
  /// run on a machine with developer mode switched on can't append its fixtures
  /// to the user's own `~/Library/Logs/Blurt/dictations.jsonl`.
  let log: RecordedLog
}

/// Builds a `SessionFixture` with everything the session reaches for stubbed:
/// the three protocol seams, the focus capture, the key terms, and the log.
/// Collapses the setup the session suites otherwise repeat.
func makeSession(
  mode: StubTranscriber.Mode = .transcript("Hello world."),
  maxRecordingSeconds: Double = SyncSTTLimits.autoReleaseSeconds,
  field: FocusCapture.FocusedFieldContext = .empty,
  frontmost: CapturedFocus? = nil,
  keyTerms: [String] = [],
  onTranscriptDelivered: (@Sendable (String, RecentDictations) -> Void)? = nil
) -> SessionFixture {
  let mic = StubMicCapture()
  let transcriber = StubTranscriber(mode: mode)
  let injector = StubInjector()
  let log = RecordedLog()
  let session = DictationSession(
    mic: mic, transcriber: transcriber, injector: injector,
    maxRecordingSeconds: maxRecordingSeconds,
    // Pinned rather than left to read the process's real `UserDefaults`, so a
    // developer's own Settings list can't change what a test sends.
    keyTermsProvider: { keyTerms },
    onTranscriptDelivered: onTranscriptDelivered,
    seams: testSeams(field: field, frontmost: frontmost, log: log))
  return SessionFixture(
    session: session, mic: mic, transcriber: transcriber, injector: injector, log: log)
}

/// Session seams with every system read replaced by a fixed value: no
/// window-server read, no cross-process Accessibility capture, and a log that
/// records in memory. `field`/`frontmost` are what the pipeline will then see as
/// the press-time context, so a test can assert on it instead of counting that
/// *something* host-dependent arrived.
func testSeams(
  field: FocusCapture.FocusedFieldContext = .empty,
  frontmost: CapturedFocus? = nil,
  log: RecordedLog = RecordedLog()
) -> DictationSession.Seams {
  DictationSession.Seams(
    captureFrontmost: { frontmost },
    captureFieldContext: { field },
    logTranscript: { log.recordTranscript($0, context: $1) },
    logFailure: { log.recordFailure($0, context: $1) })
}

extension DictationSession.Seams {
  /// The offline seams for suites that don't assert on the context or the log but
  /// must not touch the window server, the Accessibility API, or the user's real
  /// log either. Spelled at every construction site so the choice is visible.
  static var offline: DictationSession.Seams { testSeams() }
}

/// Stands in for `DictationLog` behind the session's log seams, recording what
/// would have been written. Reachable from the `@Sendable` seam closures, hence a
/// `Mutex`-guarded class rather than an actor.
final class RecordedLog: Sendable {
  struct Transcript: Sendable, Equatable {
    let text: String
    let context: TranscriptionContext?
  }

  struct Failure: Sendable {
    let error: BlurtError
    let context: TranscriptionContext?
  }

  private struct State {
    var transcripts: [Transcript] = []
    var failures: [Failure] = []
  }

  private let state = Mutex(State())

  var transcripts: [Transcript] { state.withLock { $0.transcripts } }
  var failures: [Failure] { state.withLock { $0.failures } }
  /// The stable case labels of the recorded failures — what `errors.jsonl` would
  /// aggregate on, and the readable form for an assertion.
  var failureNames: [String] { failures.map { $0.error.diagnosticName } }

  func recordTranscript(_ text: String, context: TranscriptionContext?) {
    state.withLock { $0.transcripts.append(Transcript(text: text, context: context)) }
  }

  func recordFailure(_ error: BlurtError, context: TranscriptionContext?) {
    state.withLock { $0.failures.append(Failure(error: error, context: context)) }
  }
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

  /// Suspends until a `cancel()` submitted against an in-flight command has
  /// *recorded* its request — the moment `performRelease` later consumes, and the
  /// thing a test must know happened before it releases the press it raced.
  ///
  /// Waits on the condition itself rather than draining a fixed number of
  /// `Task.yield()`s: a yield budget drains the calling task, not the session, so
  /// it could return before the cancel's first actor turn and let the release run
  /// unopposed. Unbounded on purpose — the suites carry a `.timeLimit`, so a
  /// request that never arrives fails as a timeout instead of passing quietly.
  func awaitCancelRequest() async {
    while !cancelRequested { await Task.yield() }
  }
}
