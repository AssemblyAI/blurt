import Foundation
import Synchronization

@testable import AssemblyAI
@testable import BlurtEngine

/// Plays the TTS service's side of `POST /v1/speech`. Each request is passed to
/// `respond`, which returns the status and the body's chunks, delivered as a
/// streamed response would be. Every request is recorded, so a test can read
/// back what was asked for.
final class FakeSpeechTransport: SpeechTransport, Sendable {
  /// How a response body ends once its chunks are delivered.
  enum End: Sendable {
    case finish
    case fail(any Error & Sendable)
    /// Never finishes: a stalled server.
    case hang
  }

  private let respond: @Sendable (URLRequest) -> (Int, [Data])
  private let end: End
  private let failure: (any Error & Sendable)?
  private let recorded = Mutex<[URLRequest]>([])

  var requests: [URLRequest] { recorded.withLock { $0 } }

  /// The `text` of every request, in order.
  var spoken: [String] {
    requests.compactMap { request in
      let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
      return body?["text"] as? String
    }
  }

  init(
    end: End = .finish, respond: @escaping @Sendable (URLRequest) -> (Int, [Data]) = FakeSpeechTransport.speaking()
  ) {
    self.respond = respond
    self.end = end
    self.failure = nil
  }

  /// A transport whose request fails before any response, with `error`.
  init(failing error: any Error & Sendable) {
    self.respond = { _ in (0, []) }
    self.end = .finish
    self.failure = error
  }

  /// The live service's answer: 200 and one PCM chunk per request, numbered by
  /// request, so a test can tell the pieces' audio apart.
  static func speaking() -> @Sendable (URLRequest) -> (Int, [Data]) {
    let count = Counter()
    return { _ in (200, [Data([UInt8(count.next()), 0])]) }
  }

  func stream(_ request: URLRequest) throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    recorded.withLock { $0.append(request) }
    if let failure { throw failure }
    let (status, chunks) = respond(request)
    let url = request.url ?? SpeechClient.endpoint
    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
      throw URLError(.badServerResponse)
    }
    let ending = end
    return (
      response,
      AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        switch ending {
        case .finish:
          continuation.finish()

        case .fail(let error):
          continuation.finish(throwing: error)

        case .hang:
          break
        }
      }
    )
  }
}
