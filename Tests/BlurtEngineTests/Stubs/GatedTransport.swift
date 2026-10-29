import Foundation
import Synchronization

@testable import AssemblyAI
@testable import BlurtEngine

/// Parks token-endpoint requests on `gate` while `armed`, to hold a renewal
/// or a sign-out mid-flight. Disarms after the first one it parks, so a
/// request the code under test shouldn't make reaches the server instead of
/// hanging the test. Everything else goes straight to `inner`.
final class GatedTransport: HTTPTransport, Sendable {
  let inner: FakeHTTPTransport
  let gate: Gate
  let armed = Mutex(false)

  init(inner: FakeHTTPTransport, gate: Gate) {
    self.inner = inner
    self.gate = gate
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    let hold = armed.withLock { armed in
      defer { armed = false }
      return armed && request.url == testOAuthConfiguration.tokenURL
    }
    if hold { await gate.enter() }
    return try await inner.data(for: request)
  }

  func upload(
    for request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse) {
    try await inner.upload(for: request, streaming: body, delegate: delegate)
  }
}
