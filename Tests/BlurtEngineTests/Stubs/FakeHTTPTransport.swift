import Foundation
import Synchronization

@testable import BlurtEngine

/// Per-instance `HTTPTransport` fake for the HTTP-client suites: answers each
/// request from a closure, or fails every request with a transport error.
/// Replaces the old process-global `MockURLProtocol`, so those suites need
/// neither `.serialized` ordering nor a shared responder reset — each test wires
/// its own transport into the client under test.
final class FakeHTTPTransport: HTTPTransport, Sendable {
  private let responder: @Sendable (URLRequest) -> (Int, Data)
  private let transportError: (any Error & Sendable)?

  /// `responder` maps each request to an HTTP status and JSON body.
  init(_ responder: @escaping @Sendable (URLRequest) -> (Int, Data)) {
    self.responder = responder
    self.transportError = nil
  }

  private init(transportError: any Error & Sendable) {
    self.responder = { _ in (500, Data()) }
    self.transportError = transportError
  }

  /// Every request fails with `error` (simulates offline / DNS / timeout), so a
  /// client's `catch` path can be exercised without a response.
  static func failing(with error: any Error & Sendable) -> FakeHTTPTransport {
    FakeHTTPTransport(transportError: error)
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try respond(to: request)
  }

  func upload(
    for request: URLRequest, from bodyData: Data, delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse) {
    try respond(to: request)
  }

  private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
    if let transportError { throw transportError }
    let (status, body) = responder(request)
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else { throw URLError(.badURL) }
    return (body, response)
  }
}

/// JSON-encodes a string dictionary into a canned mock response body.
func json(_ object: [String: String]) -> Data {
  (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

/// Thread-safe call counter for asserting how many requests a client issued.
final class Counter: Sendable {
  private let count = Mutex(0)
  func next() -> Int {
    count.withLock {
      $0 += 1
      return $0
    }
  }
  var value: Int {
    count.withLock { $0 }
  }
}
