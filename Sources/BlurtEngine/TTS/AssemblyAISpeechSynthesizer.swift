import Foundation

/// Speaks one piece of text through AssemblyAI's Streaming TTS HTTP API
/// (`POST /v1/speech`), as raw PCM16 little-endian mono at `sampleRate`.
/// Powers the read-aloud and ask keys (`SelectionSpeaker`,
/// `SelectionSpeechRouting`).
///
/// The API's docs are the contract (https://www.assemblyai.com/docs/tts/api-reference/http-api/create-speech),
/// as they are for the dictation API: send only what they describe.
///
/// One request per piece, its audio the response body, streamed while it is
/// synthesized: the server splits a long text into sentences itself and the
/// first ones' audio arrives long before the last. `SelectionSpeaker` cuts a
/// long selection into pieces (`ListeningChunks`) and asks for the next one only
/// as the listening catches up, so a long article starts quickly and is
/// synthesized — and billed — only as far as it is heard. HTTP rather than the
/// WebSocket API for that reason: a request per piece needs no session to keep
/// alive while reading waits on the listener, and no session lifetime caps it.
///
/// - **Request**: JSON `text`, `voice_id`, `sample_rate`, `encoding`; raw
///   audio and streaming are the defaults. Authenticate with the raw API key in
///   `Authorization`, as the dashboard shows it.
/// - **Response**: the status and headers wait for the first audio, so every
///   failure before it is an ordinary HTTP error with a JSON body (`code`,
///   `message`). Each write holds whole samples, but the network can split one,
///   so an odd byte is carried into the next chunk.
struct AssemblyAISpeechSynthesizer: Sendable {
  // MARK: - Wire format

  private struct Body: Encodable {
    enum CodingKeys: String, CodingKey {
      case text
      case voiceID = "voice_id"
      case sampleRate = "sample_rate"
      case encoding
    }

    let text: String
    let voiceID: String
    let sampleRate: Int
    let encoding: String
  }

  static let sampleRate = 24_000
  static let encoding = "pcm_s16le"
  static let endpoint = URL(staticString: "https://tts.us.assemblyai.com/v1/speech")
  /// How long the response may go quiet before the request is abandoned. A
  /// stalled server would otherwise leave the press in read-aloud mode,
  /// silent, until the next tap ended it. Real audio lands within a second or
  /// two.
  static let timeout: TimeInterval = 15

  private let apiKeyProvider: @Sendable () -> String?
  private let transport: any SpeechTransport

  /// `transport` is the network seam: production streams through
  /// `URLSession`, and the tests play the service's side.
  init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    transport: any SpeechTransport = URLSession.shared
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.transport = transport
  }

  static func request(for text: String, voiceID: String, apiKey: String) throws -> URLRequest {
    try URLRequest.assemblyAIJSONPost(
      to: endpoint,
      apiKey: apiKey,
      timeout: timeout,
      body: Body(text: text, voiceID: voiceID, sampleRate: sampleRate, encoding: encoding)
    )
  }

  /// The start of an error body: enough for any error the docs describe; a
  /// proxy's page or a stalled stream past it isn't worth waiting on.
  private static func head(of body: AsyncThrowingStream<Data, any Error>) async throws -> Data {
    var data = Data()
    for try await chunk in body {
      data.append(chunk)
      if data.count >= 65_536 { break }
    }
    return data
  }

  /// A failed request's reason: the error body's `code` and `message`, or the
  /// bare status when the body isn't one (a proxy's page).
  static func failure(status: Int, body: Data) -> String {
    let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    guard let message = (object?["message"] as? String)?.trimmedNonEmpty() else {
      return "HTTP \(status)"
    }
    if let code = object?["code"] as? String {
      return "(\(code)) \(message)"
    }
    return message
  }

  /// PCM chunks of `text` spoken by `voiceID`, in playback order, as they
  /// arrive. Blank text finishes at once without a request. Cancelling the
  /// consumer cancels the request.
  func speech(for text: String, voiceID: String = ReadAloudVoice.defaultID) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await stream(text, voiceID: voiceID) { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func stream(_ text: String, voiceID: String, onAudio: (Data) -> Void) async throws {
    guard let trimmed = text.trimmedNonEmpty() else {
      return
    }
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw BlurtError.apiKeyMissing }
    do {
      let (response, body) = try await transport.stream(
        try Self.request(for: trimmed, voiceID: voiceID, apiKey: apiKey)
      )
      guard response.statusCode == 200 else {
        let reason = Self.failure(status: response.statusCode, body: try await Self.head(of: body))
        throw SpeechSynthesisError.server(reason)
      }
      // At most the one byte of a sample the network split; whole chunks,
      // the usual case, pass straight through without a copy.
      var carry: UInt8?
      for try await chunk in body {
        var audio = chunk
        if let byte = carry {
          audio.insert(byte, at: audio.startIndex)
          carry = nil
        }
        if audio.count % 2 == 1 { carry = audio.removeLast() }
        if !audio.isEmpty { onAudio(audio) }
      }
    } catch let error as URLError where error.code == .timedOut {
      throw SpeechSynthesisError.timedOut
    } catch let error as URLError where error.code == .cancelled {
      // A stopped read cancels its request, which URLSession reports as an
      // error. It's a cancellation, and must read as one: the router beeps on
      // a failure, never on a stop.
      throw CancellationError()
    }
  }
}

extension URLSession: SpeechTransport {
  /// Hands the body on in the blocks URLSession delivers (`SpeechStreamDelegate`)
  /// rather than a byte at a time: a long read is millions of bytes.
  ///
  /// The delegate is attached before anything can cancel the task, and a
  /// cancellation settles the head itself rather than counting on URLSession
  /// to report one: a task cancelled before it was resumed (the caller already
  /// cancelled, so `onCancel` runs before the operation) may never call back,
  /// and the wait for the head would never end.
  func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    try Task.checkCancellation()
    let (body, feed) = AsyncThrowingStream<Data, any Error>.makeStream()
    let delegate = SpeechStreamDelegate(body: feed)
    let task = dataTask(with: request)
    task.delegate = delegate
    feed.onTermination = { _ in task.cancel() }
    let response = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
        // Already settled (cancelled first): the request is never sent.
        if delegate.arm(continuation) { task.resume() }
      }
    } onCancel: {
      task.cancel()
      delegate.fail(CancellationError())
    }
    return (response, body)
  }
}
