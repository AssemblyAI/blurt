import Foundation

/// A `URLProtocol` that intercepts every request and replies with whatever
/// `responder` returns, so HTTP-backed clients (`AssemblyAITranscriber`,
/// `APIKeyValidator`) can be tested without real network I/O. `responder` is
/// process-global, so any suite that installs one must run `.serialized` — see
/// `HTTPClientTests`.
final class MockURLProtocol: URLProtocol {
  // `responder` is read on URLSession's background loading thread (in
  // `startLoading`) while tests write it on their own thread (assignment and the
  // `defer` reset). `.serialized` orders the tests but not those cross-thread
  // accesses, so the storage is guarded by a lock to give them a happens-before
  // relationship — without it ThreadSanitizer (intermittently) flags a data race.
  private static let lock = NSLock()
  nonisolated(unsafe) private static var _responder: (@Sendable (URLRequest) -> (Int, Data))?

  static var responder: (@Sendable (URLRequest) -> (Int, Data))? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _responder
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _responder = newValue
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
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
final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var _value = 0
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    _value += 1
    return _value
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }
}
