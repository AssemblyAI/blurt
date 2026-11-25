import Foundation
import Testing

@testable import AssemblyAI

/// A `data(for:)` transport whose closure picks, per request, a status and body
/// or a thrown error — for a client's retry policy, which turns on which
/// request failed and how (`FakeHTTPTransport.failing` fails every one alike).
struct ScriptedTransport: GatewayStub {
  let responder: @Sendable (URLRequest) -> Result<(Int, Data), URLError>

  init(_ responder: @escaping @Sendable (URLRequest) -> Result<(Int, Data), URLError>) {
    self.responder = responder
  }

  func data(for request: URLRequest) throws -> (Data, URLResponse) {
    let (status, body) = try responder(request).get()
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    return (body, response)
  }
}
