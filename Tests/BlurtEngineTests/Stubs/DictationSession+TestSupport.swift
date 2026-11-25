import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

extension DictationSession {
  /// One whole dictation: press, release, and wait for the pipeline to settle.
  /// The shape most session tests drive before asserting on the outcome.
  func dictate(handingBack: Bool = false, key: TriggerKey? = nil) async {
    await press(handingBack: handingBack, key: key)
    await release()
    await waitForIdle()
  }

  /// Completes when the session reaches a terminal phase (idle/failed). Lives in
  /// the test target rather than the engine because only tests await terminal
  /// states; the production app drives off `phaseStream()` directly.
  func waitForIdle() async {
    if phase.isTerminal {
      return
    }
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

extension DictationSession.Seams {
  /// The offline seams for suites that don't assert on the context or the log but
  /// must not touch the window server, the Accessibility API, or the user's real
  /// log either. Spelled at every construction site so the choice is visible.
  static var offline: DictationSession.Seams { testSeams() }
}
