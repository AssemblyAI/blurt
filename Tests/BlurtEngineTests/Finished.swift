import Synchronization

/// Set once a drain under test has returned, read by the loop stepping its
/// clock (`StreamingPCMPlayerTests`).
final class Finished: Sendable {
  private let state = Mutex(false)

  var value: Bool { state.withLock { $0 } }

  func set() { state.withLock { $0 = true } }
}
