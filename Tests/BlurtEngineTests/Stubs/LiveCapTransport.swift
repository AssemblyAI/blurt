import Foundation
import Synchronization

@testable import AssemblyAI
@testable import BlurtEngine

/// `HTTPTransport` double for the over-cap fallback: answers the streaming
/// request with a configurable status, optionally **while the body is still
/// being written** — the way `/v1/transcribe/live` answers a recording that runs
/// past its cap — and answers the buffered request (`data(for:)`) separately.
///
/// What `FakeHTTPTransport` can't do is the mid-upload half. It drains the whole
/// body before answering, so a recording refused part-way could never be
/// modelled, and the bug this covers — audio captured after the refusal being
/// dropped — is precisely what happens after that point. So this one reads the
/// body on a task of its own and, once `answerAfterBytes` have arrived, cancels
/// that reader and answers, which is what `ChunkedRequestBody.send` does when an
/// early response lands: the cancelled read tears the body stream down, and the
/// producer behind it with it.
final class LiveCapTransport: HTTPTransport, Sendable {
  struct Answer: Sendable {
    var status: Int
    var body: Data
  }

  private struct State {
    var liveBody = Data()
    var bufferedRequests: [URLRequest] = []
  }

  private let live: Answer
  /// Answer the streaming request once this many body bytes have arrived, while
  /// the body is still open; nil answers only after the body ends.
  private let answerAfterBytes: Int?
  private let buffered: Answer
  /// When set, the buffered request parks here before answering, so a session
  /// test can look at the phase while the fallback is in flight.
  private let bufferedHold: Gate?
  private let state = Mutex(State())
  private let liveAnswered = AsyncGate()

  init(live: Answer, answerAfterBytes: Int? = nil, buffered: Answer, bufferedHold: Gate? = nil) {
    self.live = live
    self.answerAfterBytes = answerAfterBytes
    self.buffered = buffered
    self.bufferedHold = bufferedHold
  }

  func upload(
    for request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    delegate: (any URLSessionTaskDelegate)?
  ) async throws -> (Data, URLResponse) {
    let threshold = answerAfterBytes
    let reached = AsyncGate()
    let reader = Task {
      do {
        for try await chunk in body {
          let total = self.record(chunk)
          if let threshold, total >= threshold { reached.open() }
        }
      } catch {}
      reached.open()
    }
    await reached.wait()
    reader.cancel()
    _ = await reader.result
    liveAnswered.open()
    return try respond(to: request, with: live)
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    state.withLock { $0.bufferedRequests.append(request) }
    await bufferedHold?.enter()
    return try respond(to: request, with: buffered)
  }

  /// Appends a chunk of the streamed body and returns the running total.
  private func record(_ chunk: Data) -> Int {
    state.withLock {
      $0.liveBody.append(chunk)
      return $0.liveBody.count
    }
  }

  /// Returns once the streaming request has been answered — so a test can feed
  /// audio that is certain to arrive *after* the refusal.
  func waitUntilLiveAnswered() async { await liveAnswered.wait() }

  /// Every byte the streaming request's body carried before it was answered.
  var liveBody: Data { state.withLock { $0.liveBody } }
  /// The buffered requests made, in order — the fallback sends at most one.
  var bufferedRequests: [URLRequest] { state.withLock { $0.bufferedRequests } }

  private func respond(to request: URLRequest, with answer: Answer) throws -> (Data, URLResponse) {
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: answer.status, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])
    else { throw URLError(.badURL) }
    return (answer.body, response)
  }
}

extension LiveCapTransport.Answer {
  /// The streaming route's documented refusal past its cap.
  static let audioTooLarge = Self(
    status: 413, body: json(["error": "audio exceeds 120000 ms", "error_code": "audio_too_large"]))

  /// A 200 carrying `text` as the verbatim transcript and `rewrite` as the
  /// cleanup rewrite.
  static func transcript(_ text: String, rewrite: String) -> Self {
    Self(status: 200, body: json(["text": text, "llm_response": rewrite]))
  }

  /// An answer the test never expects to be reached; a 500 so reaching it fails
  /// loudly rather than passing on an empty body.
  static let unreachable = Self(status: 500, body: json(["error": "unexpected request"]))
}
