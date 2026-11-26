import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A gateway answering rewrite requests only as the test releases them, each
/// answer naming its request: "Rewritten 1.", "Rewritten 2.", …
final class GatedRewrites: GatewayStub, Sendable {
  private struct State {
    var asked = 0
    var released = 0
    /// The requests still held, by number, each parked on its own gate.
    var held: [Int: AsyncGate] = [:]
  }

  private let state = Mutex(State())

  var asked: Int { state.withLock(\.asked) }

  func release(_ count: Int) {
    let freed = state.withLock { state -> [AsyncGate] in
      state.released = count == .max ? .max : state.released + count
      let released = state.released
      let due = state.held.filter { $0.key <= released }
      for number in due.keys { state.held[number] = nil }
      return Array(due.values)
    }
    for gate in freed { gate.open() }
  }

  /// Parks on the request's own gate rather than polling. `AsyncGate.wait()`
  /// doesn't answer cancellation itself, so the cancellation handler opens the
  /// gate and the request then throws, as a real one torn down mid-flight does.
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let gate = AsyncGate()
    let (number, held) = state.withLock { state -> (Int, Bool) in
      state.asked += 1
      let held = state.released < state.asked
      if held { state.held[state.asked] = gate }
      return (state.asked, held)
    }
    if held {
      await withTaskCancellationHandler {
        await gate.wait()
      } onCancel: {
        gate.open()
      }
      try Task.checkCancellation()
    }
    return try ok(request, completion("Rewritten \(number). The words read aloud."))
  }
}
