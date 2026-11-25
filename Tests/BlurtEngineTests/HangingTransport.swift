import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A gateway that never answers, until the request's task is cancelled.
final class HangingTransport: GatewayStub {
  private let called = Mutex(false)
  var asked: Bool { called.withLock { $0 } }

  func data(for _: URLRequest) async throws -> (Data, URLResponse) {
    called.withLock { $0 = true }
    try await Task.sleep(for: .seconds(60))
    throw URLError(.timedOut)
  }
}
