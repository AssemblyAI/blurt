import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// Builds a `SessionFixture` with everything the session reaches for stubbed:
/// the three protocol seams, the focus capture, the key terms, and the log.
/// Collapses the setup the session suites otherwise repeat.
func makeSession(
  mode: StubTranscriber.Mode = .transcript("Hello world."),
  maxRecordingSeconds: Double = RecordingLimits.autoReleaseSeconds,
  field: FocusedFieldContext = .empty,
  frontmost: CapturedFocus? = nil,
  keyTerms: [String] = [],
  textShortcuts: [TextShortcut] = [],
  pressStyle: @escaping @Sendable (TriggerKey?) -> PressStyle = { _ in PressStyle.base },
  onTranscriptDelivered: (@Sendable (String, RecentDictations) -> Void)? = nil
) -> SessionFixture {
  let mic = StubMicCapture()
  let transcriber = StubTranscriber(mode: mode)
  let injector = StubInjector()
  let log = RecordedLog()
  let session = DictationSession(
    mic: mic,
    transcriber: transcriber,
    injector: injector,
    maxRecordingSeconds: maxRecordingSeconds,
    clock: ContinuousClock(),  // wall-clock-ok: the production clock, for tests that aren't about its timers
    // Pinned rather than left to read the process's real `UserDefaults`, so a
    // developer's own Settings list can't change what a test sends.
    keyTermsProvider: { keyTerms },
    pressStyleProvider: pressStyle,
    textShortcutsProvider: { textShortcuts },
    readinessCheck: { nil },
    onTranscriptDelivered: onTranscriptDelivered,
    seams: testSeams(field: field, frontmost: frontmost, log: log)
  )
  return SessionFixture(
    session: session, mic: mic, transcriber: transcriber, injector: injector, log: log
  )
}

/// Session seams with every system read replaced by a fixed value: no
/// window-server read, no cross-process Accessibility capture, and a log that
/// records in memory. `field`/`frontmost` are what the pipeline will then see as
/// the press-time context, so a test can assert on it instead of counting that
/// *something* host-dependent arrived.
func testSeams(
  field: FocusedFieldContext = .empty,
  frontmost: CapturedFocus? = nil,
  log: RecordedLog = RecordedLog()
) -> DictationSession.Seams {
  DictationSession.Seams(
    captureFrontmost: { frontmost },
    captureFieldContext: { field },
    logTranscript: { log.recordTranscript($0, context: $1, outcome: $2) },
    logFailure: { log.recordFailure($0, context: $1) }
  )
}

/// Seams whose field capture blocks until the returned semaphore is signalled —
/// a beachballing frontmost app, which is what holds the pipeline inside its
/// bounded context wait long enough for a test to land something there.
///
/// A factory rather than each suite hand-writing `DictationSession.Seams`: two
/// did, and both copies quietly dropped the transcript recording `testSeams`
/// wires up, so a later assertion on `log.transcripts` would have seen nothing.
func hungFieldSeams(
  field: FocusedFieldContext = .empty,
  log: RecordedLog = RecordedLog()
) -> (seams: DictationSession.Seams, release: DispatchSemaphore) {
  let hung = DispatchSemaphore(value: 0)
  var seams = testSeams(log: log)
  seams.captureFieldContext = {
    hung.wait()
    return field
  }
  return (seams, hung)
}

/// A session wired to the doubles a test hands it — a gated mic, injector or
/// transcriber, a test clock, a readiness gate — which `makeSession(mode:)` cannot
/// do: it hard-codes the stubs, and the race and upload suites need doubles that
/// report *when* they were called. Here beside `makeSession` so the two don't
/// drift. Between them they are the only way a test builds a session, which is
/// what lets the seam-carrying initializer leave every default to the public one.
///
/// `keyTermsProvider` overrides `keyTerms` for a test that counts the reads.
func makeSession(
  transcriber: any TranscriberProtocol,
  mic: any MicCaptureProtocol = StubMicCapture(),
  injector: any InjectorProtocol = StubInjector(),
  maxRecordingSeconds: Double = RecordingLimits.autoReleaseSeconds,
  // wall-clock-ok: the production clock, for tests that aren't about its timers
  clock: any Clock<Duration> = ContinuousClock(),
  keyTerms: [String] = [],
  keyTermsProvider: (@Sendable () -> [String])? = nil,
  pressStyle: @escaping @Sendable (TriggerKey?) -> PressStyle = { _ in PressStyle.base },
  readinessCheck: @escaping @Sendable () -> BlurtError? = { nil },
  seams: DictationSession.Seams = .offline
) -> DictationSession {
  DictationSession(
    mic: mic,
    transcriber: transcriber,
    injector: injector,
    maxRecordingSeconds: maxRecordingSeconds,
    clock: clock,
    keyTermsProvider: keyTermsProvider ?? { keyTerms },
    pressStyleProvider: pressStyle,
    textShortcutsProvider: { [] },
    readinessCheck: readinessCheck,
    onTranscriptDelivered: nil,
    seams: seams
  )
}

/// Waits for the fixture's mic to start: a hand-back press has opened it, so a
/// release now ends a recording rather than racing the press. Up to 30 s, as
/// `waitUntil`: the bound only catches a hang, and a stalled runner outlasts 5 s.
func waitForMicStart(_ fixture: SessionFixture) async throws {
  let deadline = ContinuousClock.now + .seconds(30)
  while await fixture.mic.startCalls == 0, ContinuousClock.now < deadline {
    // wall-clock-ok: the poll's own tick; the loop is bounded only against a hang
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// Feeds `fixture`'s session phases to `router`, returning the wiring for the
/// caller to cancel once the first phase has landed. Every subscription opens
/// with the session's current phase, and a hand-back press that opens the mic
/// before that replay lands takes the replayed idle for its own request's end
/// — a race a real hold delay used to hide, and a stepped one doesn't.
@MainActor
func wirePhases(of fixture: SessionFixture, to router: SelectionSpeechRouter) async -> Task<Void, Never> {
  let (landed, signal) = AsyncStream.makeStream(of: Void.self)
  let phases = Task {
    for await phase in await fixture.session.phaseStream() {
      router.sessionPhaseChanged(phase)
      signal.finish()
    }
  }
  for await _ in landed {
    // Returns once the first phase has been delivered and the stream finished.
  }
  return phases
}

/// One held hand-back press of right ⌥ through `router` — a rewrite's
/// instruction or a command — recorded by `fixture`'s session and let go, the
/// session's phases wired to the router first. Returns that wiring, for the
/// caller to cancel.
///
/// `clock` is the router's: the press becomes a hold when its hold timer fires,
/// so the timer is stepped here rather than waited out — a real 300 ms timer
/// behind a bounded poll is what failed on a loaded CI runner.
@MainActor
func speakHeldPress(
  _ router: SelectionSpeechRouter, on fixture: SessionFixture, clock: TestClock
) async throws -> Task<Void, Never> {
  let phases = await wirePhases(of: fixture, to: router)
  router.press(key: .rightOption)
  await clock.waitUntilSleeping(for: SelectionSpeechRouting.holdDelay)
  clock.advance(by: SelectionSpeechRouting.holdDelay)
  try await waitForMicStart(fixture)
  router.submit(.release)
  return phases
}

typealias StubRewriter = StubWriter<RewriteCall>
typealias StubComposer = StubWriter<ComposeCall>

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
