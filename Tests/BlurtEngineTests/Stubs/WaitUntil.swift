/// Polls `condition` every few milliseconds until it holds, or throws after
/// `timeout` — for state a test can't await directly (a router's callbacks, a
/// background task's effects).
///
/// The timeout only catches a hang, so it's generous: a passing test never
/// waits it out, and on a loaded CI runner the whole parallel run can stall
/// for seconds before a test's tasks get the main actor — a 5 s budget lost
/// two `SelectionSpeechRouter` tests that way, every test in that run taking
/// ~6 s.
@MainActor
func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else { throw CancellationError() }
    // wall-clock-ok: the poll's own tick; the loop is bounded only against a hang
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// The overload above for a condition that has to `await` — an actor's state,
/// a session's phase — or that a test off the main actor reads. Same tick and
/// the same hang-sized bound, but a timeout throws `WaitTimedOut` naming
/// `awaited`, so a hang reads as what never happened rather than as a bare
/// cancellation, and an unbounded `while … { await Task.yield() }` spin is
/// never the only thing standing between a test and its `.timeLimit`.
///
/// `nonisolated(nonsending)`: it runs on its caller's actor, so `condition`
/// need not be `Sendable` — a weak reference to a non-`Sendable` instance, or
/// a main-actor test's local state, can be read from it as it stands.
nonisolated(nonsending) func waitUntil(
  _ awaited: String,
  timeout: Duration = .seconds(30),
  _ condition: () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while await !condition() {
    guard ContinuousClock.now < deadline else { throw WaitTimedOut(awaited: awaited, timeout: timeout) }
    // wall-clock-ok: the poll's own tick; the loop is bounded only against a hang
    try await Task.sleep(for: .milliseconds(5))
  }
}
