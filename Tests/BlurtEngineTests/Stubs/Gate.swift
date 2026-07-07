/// A two-phase gate for wedging a suspension point open in concurrency tests.
/// The seam under test calls `enter()` — which records arrival and then blocks
/// until `allowToFinish()` — while the test awaits `waitUntilEntered()` and later
/// releases it. Consolidates the per-stub `enteredWaiters`/`finishWaiters`
/// continuation bookkeeping the gated mic / transcriber / injector stubs each
/// used to hand-roll.
actor Gate {
  private var entered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var finished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  /// Called from inside the seam under test: records arrival (waking any pending
  /// `waitUntilEntered()`) and blocks until `allowToFinish()`. Tolerates being
  /// entered more than once — each caller parks until finish.
  func enter() async {
    entered = true
    enteredWaiters.forEach { $0.resume() }
    enteredWaiters.removeAll()
    guard !finished else { return }
    await withCheckedContinuation { finishWaiters.append($0) }
  }

  /// Awaited by the test: returns once the seam has called `enter()`.
  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { enteredWaiters.append($0) }
  }

  /// Releases every caller parked in `enter()`.
  func allowToFinish() {
    finished = true
    finishWaiters.forEach { $0.resume() }
    finishWaiters.removeAll()
  }
}
