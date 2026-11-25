import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A gateway that ignores cancellation: it waits for `release()`, then answers
/// 200 anyway, the way a response already in flight lands after a stop.
final class LateAnsweringTransport: GatewayStub {
  private let state = Mutex((asked: false, released: false))
  var asked: Bool { state.withLock { $0.asked } }

  func release() { state.withLock { $0.released = true } }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    state.withLock { $0.asked = true }
    while !state.withLock({ $0.released }) { await Task.yield() }
    return try ok(request, completion("Say something here."))
  }
}
