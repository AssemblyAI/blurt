import Synchronization

/// A step a fake parks on until the test lets it go: the point a test means to
/// land something in (a press while the source closes, the phase while the mic
/// starts) stays open for as long as the test needs, on any runner. The
/// real-time delays these fakes took before ended on their own, and a busy
/// main actor could miss the moment entirely and wait out its `until`.
///
/// One-shot: once `release()` has run, every `wait()`, then or later, returns
/// at once.
nonisolated final class Hold: Sendable {
  private struct State {
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  /// Whether something is parked on the hold now: the step has been reached.
  var isHolding: Bool { state.withLock { !$0.waiters.isEmpty } }

  /// Parks until `release()`, or returns at once if it already ran.
  func wait() async {
    await withCheckedContinuation { waiter in
      let released = state.withLock { state in
        if !state.released {
          state.waiters.append(waiter)
        }
        return state.released
      }
      if released { waiter.resume() }
    }
  }

  /// Lets every parked `wait()` go on, and every later one through.
  func release() {
    let waiters = state.withLock { state in
      state.released = true
      defer { state.waiters.removeAll() }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }
}
