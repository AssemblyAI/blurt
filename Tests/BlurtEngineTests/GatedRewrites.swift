import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A gateway answering rewrite requests only as the test releases them, each
/// answer naming its request: "Rewritten 1.", "Rewritten 2.", …
final class GatedRewrites: GatewayStub, Sendable {
  private let state = Mutex((asked: 0, released: 0))

  var asked: Int { state.withLock(\.asked) }

  func release(_ count: Int) {
    state.withLock { $0.released = count == .max ? .max : $0.released + count }
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let number = state.withLock { state -> Int in
      state.asked += 1
      return state.asked
    }
    while state.withLock({ $0.released < number }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    return try ok(request, completion("Rewritten \(number). The words read aloud."))
  }
}
