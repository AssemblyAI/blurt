import Foundation
import Synchronization
import Testing

@testable import AssemblyAI
@testable import BlurtEngine

/// An LLM Gateway stub: read-aloud only ever asks the gateway with
/// `data(for:)`, so a streaming upload is unreachable and needn't be restated
/// by each stub.
protocol GatewayStub: HTTPTransport {}

extension GatewayStub {
  func upload(
    for _: URLRequest,
    streaming _: AsyncThrowingStream<Data, any Error>,
    delegate _: (any URLSessionTaskDelegate)?
  ) throws -> (Data, URLResponse) {
    throw URLError(.unsupportedURL)
  }

  /// A 200 answering `request` with `body`.
  func ok(_ request: URLRequest, _ body: Data) throws -> (Data, URLResponse) {
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    return (body, response)
  }
}
