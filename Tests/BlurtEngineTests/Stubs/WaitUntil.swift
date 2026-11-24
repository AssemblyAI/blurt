/// Polls `condition` every few milliseconds until it holds, or throws once
/// `timeout`'s worth of polls has gone by without it — for state a test can't
/// await directly (a router's callbacks, a background task's effects).
///
/// The budget is counted in polls, not wall-clock time. The poll and the work
/// it waits on share the main actor, and on CI — the whole suite starting at
/// once — that actor can be contended for seconds at a stretch. A wall-clock
/// deadline spent that stall with neither side running, then woke past it and
/// failed before the work queued ahead of it had run (`SelectionSpeechRouter`'s
/// tap-read test did). A stall delays a poll as much as the work, so it costs
/// no polls; a genuine hang still fails after at least `timeout`.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
  let interval = Duration.milliseconds(5)
  var pollsLeft = Int(timeout / interval)
  while !condition() {
    guard pollsLeft > 0 else { throw CancellationError() }
    pollsLeft -= 1
    try await Task.sleep(for: interval)
  }
}
