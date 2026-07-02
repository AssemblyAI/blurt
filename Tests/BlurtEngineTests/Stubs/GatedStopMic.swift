@testable import BlurtEngine

/// Mic stub whose `stop()` signals entry and then blocks until the test releases
/// it, so a second `release()`/`cancel()` can be landed deterministically while
/// the first caller is suspended inside `mic.stop()`. Tolerates concurrent
/// `stop()` calls (the regressions under test trigger a second). An injected
/// `stopError` is thrown once the gate opens, for the failing-stop variants.
actor GatedStopMic: MicCaptureProtocol {
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private let stopError: (any Error & Sendable)?
  private var stopEntered = false
  private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
  private var finished = false
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  init(stopError: (any Error & Sendable)? = nil) {
    self.stopError = stopError
  }

  nonisolated func start() async throws { await incStart() }
  private func incStart() { startCalls += 1 }

  nonisolated func stop() async throws -> [Float] { try await enterStop() }

  private func enterStop() async throws -> [Float] {
    stopCalls += 1
    stopEntered = true
    for waiter in enteredWaiters { waiter.resume() }
    enteredWaiters.removeAll()
    if !finished {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        finishWaiters.append(c)
      }
    }
    if let stopError { throw stopError }
    // Above SyncSTTLimits.minSamples so the transcript isn't dropped by the
    // too-short guard — these suites exercise stop races, not it.
    return Array(repeating: 0, count: SyncSTTLimits.minSamples * 2)
  }

  func waitUntilStopEntered() async {
    if stopEntered { return }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      enteredWaiters.append(c)
    }
  }

  func allowStopToFinish() {
    finished = true
    for waiter in finishWaiters { waiter.resume() }
    finishWaiters.removeAll()
  }
}
