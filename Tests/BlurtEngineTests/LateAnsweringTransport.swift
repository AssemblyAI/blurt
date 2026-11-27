import Foundation
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// A gateway that ignores cancellation: it waits for `release()`, then answers
/// 200 anyway, the way a response already in flight lands after a stop.
///
/// A `Gate` rather than a polled flag: the request records its arrival, which
/// the test awaits, then parks until released — and `AsyncGate.wait()` not
/// answering cancellation is exactly the deafness this fake stands for.
final class LateAnsweringTransport: GatewayStub {
  private let gate = Gate()

  /// Returns once the request has arrived.
  func waitUntilAsked() async { await gate.waitUntilEntered() }

  func release() { gate.allowToFinish() }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    await gate.enter()
    return try ok(request, completion("Say something here."))
  }
}
