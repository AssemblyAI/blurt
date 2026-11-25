public import Foundation

/// The one network call the TTS client makes: a request whose response body
/// is read as it arrives. `URLSession` is the production conformance; tests
/// play the service.
public protocol SpeechTransport: Sendable {
  /// The response head, once it arrives, and its body as it streams in.
  func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>)
}
