import Foundation

/// The one network call the synthesizer makes: a request whose response body
/// is read as it arrives. `URLSession` is the production conformance; the tests
/// play the service.
protocol SpeechTransport: Sendable {
  /// The response head, once it arrives, and its body as it streams in.
  func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)
}
