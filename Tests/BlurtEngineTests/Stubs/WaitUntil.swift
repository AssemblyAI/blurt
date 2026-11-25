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
    try await Task.sleep(for: .milliseconds(5))
  }
}
