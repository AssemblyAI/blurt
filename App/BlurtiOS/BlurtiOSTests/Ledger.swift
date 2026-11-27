import Synchronization

// MARK: - The window's collaborators, faked
//
// Everything the interpreter is injected with: a source that does what it is
// told and counts it, an audio session and background tasks that count too,
// an idle mode that reports what it is asked, the application's state as a
// box, and a clock the test advances by hand. `WindowRig` wires them into one
// window. A `Ledger` the source and the idle mode both write to says in what
// order the window asked them.

/// What happened, in order, across the fakes: one line per call, from any thread.
nonisolated final class Ledger: Sendable {
  private let entries = Mutex<[String]>([])

  var lines: [String] { entries.withLock { $0 } }

  func note(_ line: String) { entries.withLock { $0.append(line) } }
}

/// Polls until `condition` holds or `timeout` passes; true when it held.
///
/// The timeout only catches a hang, so it's generous: every caller expects
/// the condition to hold, so a passing test never waits it out. Under the
/// sanitizers on a loaded runner, a dictation's release took longer than the
/// 3 s this used to allow (the watchdog-release test, lost on its `.noTarget`).
@MainActor
func until(_ timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() {
      return true
    }
    // wall-clock-ok: the poll's own tick; the loop is bounded only against a hang
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// Waits, bounded as `until` is, for a sleeper due exactly `duration` from now
/// to park on `clock`; true when one did. `TestClock.waitUntilSleeping` waits
/// for the same thing without a bound, which suits the engine's suites, each
/// under a `.timeLimit`; these carry none, so a timer that never parks would
/// hang the whole run there instead of failing the one test here.
func parked(on clock: TestClock, for duration: Duration) async -> Bool {
  await until { clock.sleepingFor.contains(duration) }
}
