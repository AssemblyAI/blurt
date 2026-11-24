/// Polls `condition` every few milliseconds until it holds, or throws after
/// `timeout` — for state a test can't await directly (a router's callbacks, a
/// background task's effects).
///
/// The budget only bounds a genuine hang, so it is generous: on CI the whole
/// suite starts at once and the main actor — which this poll and the work it
/// waits on share — can be contended for several seconds, long enough that a
/// 5 s budget expired before the router's queued tasks ever ran.
@MainActor
func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else { throw CancellationError() }
    try await Task.sleep(for: .milliseconds(5))
  }
}
