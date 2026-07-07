import Foundation

/// The two `URLSession` calls the AssemblyAI clients make (`AssemblyAITranscriber`,
/// `APIKeyValidator`), behind a seam so tests substitute a per-instance fake
/// instead of registering a process-global `URLProtocol`. The signatures mirror
/// `URLSession`'s own, so the production conformance is a zero-cost
/// `extension URLSession: HTTPTransport {}` and a fake only implements two methods.
public protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
  func upload(
    for request: URLRequest, from bodyData: Data, delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse)
}

/// `URLSession` already declares both methods with these exact signatures, so it
/// satisfies `HTTPTransport` without any wrapper.
extension URLSession: HTTPTransport {}
