import Foundation
import Synchronization

/// A `URLProtocol` that intercepts every request and replies with whatever
/// `responder` returns, so HTTP-backed clients (`AssemblyAITranscriber`,
/// `APIKeyValidator`) can be tested without real network I/O. `responder` is
/// process-global, so any suite that installs one must run `.serialized` — see
/// `HTTPClientTests`.
final class MockURLProtocol: URLProtocol {
  // `responder` is read on URLSession's background loading thread (in
  // `startLoading`) while tests write it on their own thread (assignment and the
  // `defer` reset). `.serialized` orders the tests but not those cross-thread
  // accesses, so the storage lives in a `Mutex` to give them a happens-before
  // relationship — without it ThreadSanitizer (intermittently) flags a data race.
  private static let _responder = Mutex<(@Sendable (URLRequest) -> (Int, Data))?>(nil)
  private static let _transportError = Mutex<(any Error & Sendable)?>(nil)

  static var responder: (@Sendable (URLRequest) -> (Int, Data))? {
    get { _responder.withLock { $0 } }
    set { _responder.withLock { $0 = newValue } }
  }

  /// When set, every request fails with this error instead of receiving a
  /// response — simulating a transport failure (offline, DNS, timeout) so
  /// clients' `catch` paths can be exercised. Takes precedence over `responder`;
  /// same cross-thread locking rationale as above.
  static var transportError: (any Error & Sendable)? {
    get { _transportError.withLock { $0 } }
    set { _transportError.withLock { $0 = newValue } }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    if let error = MockURLProtocol.transportError {
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    let (status, body) = MockURLProtocol.responder?(request) ?? (500, Data())
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// A `URLSession` whose only protocol is `MockURLProtocol`, so every request it
/// issues is answered by the current `MockURLProtocol.responder`.
func mockURLSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [MockURLProtocol.self]
  return URLSession(configuration: config)
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
