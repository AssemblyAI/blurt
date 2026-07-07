import Foundation
import Synchronization

/// A manually-advanced `Clock` for deterministic timer tests: a `sleep` parks
/// until `advance(by:)` moves virtual time past its deadline (or the sleeping
/// task is cancelled). No wall-clock waiting, so the auto-release timer can be
/// exercised without racing real milliseconds.
final class TestClock: Clock, Sendable {
  struct Instant: InstantProtocol {
    let offset: Duration
    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let id: Int
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }
  private struct State {
    var now = Instant(offset: .zero)
    var sleepers: [Sleeper] = []
    var nextID = 0
  }
  private let state = Mutex(State())

  var now: Instant { state.withLock { $0.now } }
  var minimumResolution: Duration { .zero }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = state.withLock { s -> Int in
      s.nextID += 1
      return s.nextID
    }
    enum Resume { case park, fire, cancel }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
        // Decide under the lock so a concurrent `cancel()` / `advance()` can't
        // slip between the checks and the append — closing the already-cancelled
        // and already-past-deadline races.
        let resume = state.withLock { s -> Resume in
          if Task.isCancelled { return .cancel }
          if s.now >= deadline { return .fire }
          s.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: cont))
          return .park
        }
        switch resume {
        case .park: break
        case .fire: cont.resume()
        case .cancel: cont.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      let cont = state.withLock { s -> CheckedContinuation<Void, any Error>? in
        guard let index = s.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return s.sleepers.remove(at: index).continuation
      }
      cont?.resume(throwing: CancellationError())
    }
  }

  /// Advance virtual time, waking every sleeper whose deadline has now passed.
  func advance(by duration: Duration) {
    let toWake = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
      s.now = s.now.advanced(by: duration)
      let ready = s.sleepers.filter { $0.deadline <= s.now }
      s.sleepers.removeAll { $0.deadline <= s.now }
      return ready.map(\.continuation)
    }
    for continuation in toWake { continuation.resume() }
  }
}
