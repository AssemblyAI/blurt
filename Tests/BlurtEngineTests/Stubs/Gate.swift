/// A two-phase gate for wedging a suspension point open in concurrency tests.
/// The seam under test calls `enter()` — which records arrival and then blocks
/// until `allowToFinish()` — while the test awaits `waitUntilEntered()` and later
/// releases it.
///
/// Two `AsyncGate`s rather than its own continuation bookkeeping: one-shot gating
/// is one primitive, and this is that primitive used twice — once for "the seam
/// got here", once for "the seam may go on".
struct Gate: Sendable {
  private let entered = AsyncGate()
  private let finished = AsyncGate()

  /// Called from inside the seam under test: records arrival (waking any pending
  /// `waitUntilEntered()`) and blocks until `allowToFinish()`. Tolerates being
  /// entered more than once — each caller parks until finish — and an
  /// `allowToFinish()` that already happened (the caller then returns straight
  /// away).
  func enter() async {
    entered.open()
    await finished.wait()
  }

  /// Awaited by the test: returns once the seam has called `enter()`.
  func waitUntilEntered() async {
    await entered.wait()
  }

  /// Releases every caller parked in `enter()`.
  func allowToFinish() {
    finished.open()
  }
}
