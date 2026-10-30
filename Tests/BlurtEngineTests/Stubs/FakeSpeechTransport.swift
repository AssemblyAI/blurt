import Foundation
import Synchronization

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

  var requests: [URLRequest] { recorded.withLock { $0 } }

  /// The `text` of every request, in order.
  var spoken: [String] {
    requests.compactMap { request in
      let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
      return body?["text"] as? String
    }
  }

  func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
    recorded.withLock { $0.append(request) }
    if let failure { throw failure }
    let (status, chunks) = respond(request)
    let url = request.url ?? AssemblyAISpeechSynthesizer.endpoint
    guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
      throw URLError(.badServerResponse)
    }
    let end = end
    return (
      response,
      AsyncThrowingStream { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        switch end {
        case .finish: continuation.finish()
        case .fail(let error): continuation.finish(throwing: error)
        case .hang: break
        }
      }
    )
  }

  /// The live service's answer: 200 and one PCM chunk per request, numbered by
  /// request, so a test can tell the pieces' audio apart.
  static func speaking() -> @Sendable (URLRequest) -> (Int, [Data]) {
    let count = Counter()
    return { _ in (200, [Data([UInt8(count.next()), 0])]) }
  }
}

/// A `PCMSink` that records what it's asked to do instead of playing it. For
/// the pacing tests, `bufferedSeconds` can be set, and `bufferedAfterEnqueue`
/// makes each enqueue report that much audio queued, as a real player would.
final class RecordingSink: PCMSink {
  struct Record {
    var chunks: [Data] = []
    var drained = false
    var stopped = false
    var buffered: Double = 0
    var bufferedAfterEnqueue: Double?
  }

  let record = Mutex(Record())

  func enqueue(_ pcm: Data) {
    record.withLock { record in
      record.chunks.append(pcm)
      if let queued = record.bufferedAfterEnqueue { record.buffered = queued }
    }
  }
  func drain() async { record.withLock { $0.drained = true } }
  func stop() { record.withLock { $0.stopped = true } }

  var chunks: [Data] { record.withLock(\.chunks) }
  var drained: Bool { record.withLock(\.drained) }
  var stopped: Bool { record.withLock(\.stopped) }
  var bufferedSeconds: Double {
    get { record.withLock(\.buffered) }
    set { record.withLock { $0.buffered = newValue } }
  }
  var bufferedAfterEnqueue: Double? {
    get { record.withLock(\.bufferedAfterEnqueue) }
    set { record.withLock { $0.bufferedAfterEnqueue = newValue } }
  }
}
