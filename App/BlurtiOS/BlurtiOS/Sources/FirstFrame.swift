import Synchronization

/// The handshake between a press waiting on a parked microphone and the
/// delivery queue's first frame. Armed before the session starts, so a frame
/// that lands before anyone waits is still counted.
nonisolated final class FirstFrame: Sendable {
  private enum State {
    case idle
    case armed
    case arrived
    case waiting(CheckedContinuation<Bool, Never>)
  }

  private let state = Mutex(State.idle)

  func arm() { state.withLock { $0 = .armed } }

  /// A frame was delivered: wakes the press waiting on it, if any.
  func arrived() {
    let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      switch state {
      case .armed:
        state = .arrived
        return nil
      case .waiting(let continuation):
        state = .idle
        return continuation
      case .idle, .arrived:
        return nil
      }
    }
    waiter?.resume(returning: true)
  }

  /// Whether a frame arrives within `timeout` of arming.
  func wait(timeout: Duration) async -> Bool {
    let timer = Task {
      // Only a timer that ran out fails the wait; one cancelled because the
      // wait ended must not touch the next press's state.
      guard (try? await Task.sleep(for: timeout)) != nil else { return }
      cancel()
    }
    defer { timer.cancel() }
    return await withCheckedContinuation { continuation in
      let early = state.withLock { state -> Bool? in
        switch state {
        case .arrived:
          state = .idle
          return true
        case .armed:
          state = .waiting(continuation)
          return nil
        case .idle, .waiting:
          // Cancelled before the wait began.
          return false
        }
      }
      if let early { continuation.resume(returning: early) }
    }
  }

  /// Ends any wait as a failure.
  func cancel() {
    let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      defer { state = .idle }
      if case .waiting(let continuation) = state { return continuation }
      return nil
    }
    waiter?.resume(returning: false)
  }
}
