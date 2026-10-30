/// Polls `condition` every few milliseconds until it holds, or throws after
/// `timeout` — for state a test can't await directly (a router's callbacks, a
/// background task's effects).
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else { throw CancellationError() }
    try await Task.sleep(for: .milliseconds(5))
  }
}
