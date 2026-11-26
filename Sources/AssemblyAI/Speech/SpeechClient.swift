public import Foundation

/// Speaks one piece of text through AssemblyAI's Streaming TTS HTTP API
/// (`POST /v1/speech`), as raw PCM16 little-endian mono at `sampleRate`.
///
/// The API's docs are the contract (https://www.assemblyai.com/docs/tts/api-reference/http-api/create-speech),
/// as they are for the dictation API: send only what they describe.
///
/// One request per piece, its audio the response body, streamed while it is
/// synthesized: the server splits a long text into sentences itself and the
/// first ones' audio arrives long before the last. A caller reading a long
/// text can cut it into pieces and ask for the next one only as the listening
/// catches up, so it is synthesized — and billed — only as far as it is heard.
/// HTTP rather than the WebSocket API for that reason: a request per piece
/// needs no session to keep alive while reading waits on the listener, and no
/// session lifetime caps it.
///
/// - **Request**: JSON `text`, `voice_id`, `sample_rate`, `encoding`; raw
///   audio and streaming are the defaults. Authenticate with the raw API key in
///   `Authorization`, as the dashboard shows it.
/// - **Response**: the status and headers wait for the first audio, so every
///   failure before it is an ordinary HTTP error with a JSON body (`code`,
///   `message`). Each write holds whole samples, but the network can split one,
///   so an odd byte is carried into the next chunk.
public struct SpeechClient: Sendable {
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

  /// A failed request's JSON body. Each field is read on its own, so a `code`
  /// of another type doesn't lose the `message`.
  private struct ErrorBody: Decodable {
    enum CodingKeys: String, CodingKey {
      case code, message
    }

    let code: String?
    let message: String?

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      code = try? container.decode(String.self, forKey: .code)
      message = try? container.decode(String.self, forKey: .message)
    }
  }

  /// The rate every chunk is spoken at: PCM16 mono at 24 kHz.
  public static let sampleRate = 24_000
  static let encoding = "pcm_s16le"
  static let endpoint = URL(literal: "https://tts.us.assemblyai.com/v1/speech")
  /// How long the response may go quiet before the request is abandoned. A
  /// stalled server would otherwise leave a read silent indefinitely. Real
  /// audio lands within a second or two.
  static let timeout: TimeInterval = 15

  private let transport: any SpeechTransport
  private let userAgent: String?

  /// `transport` is the network seam: production streams through
  /// `URLSession`, and tests play the service's side. `userAgent` names the
  /// calling app; nil sends URLSession's default.
  public init(transport: any SpeechTransport = URLSession.shared, userAgent: String? = nil) {
    self.transport = transport
    self.userAgent = userAgent
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
    let object = try? JSONDecoder().decode(ErrorBody.self, from: body)
    guard let message = object?.message?.trimmedNonEmpty() else {
      return "HTTP \(status)"
    }
    if let code = object?.code {
      return "(\(code)) \(message)"
    }
    return message
  }

  /// PCM chunks of `text` spoken by `voiceID`, in playback order, as they
  /// arrive. Blank text finishes at once without a request. Cancelling the
  /// consumer cancels the request.
  public func speech(for text: String, voiceID: String, apiKey: String) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await stream(text, voiceID: voiceID, apiKey: apiKey) { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func stream(_ text: String, voiceID: String, apiKey: String, onAudio: (Data) -> Void) async throws {
    guard let trimmed = text.trimmedNonEmpty() else {
      return
    }
    do {
      let (response, body) = try await transport.stream(
        try request(for: trimmed, voiceID: voiceID, apiKey: apiKey)
      )
      guard response.statusCode == 200 else {
        let reason = Self.failure(status: response.statusCode, body: try await Self.head(of: body))
        throw SpeechSynthesisError.server(reason)
      }
      // The network can split a sample across chunks; the aligner carries
      // that byte over, and passes whole chunks, the usual case, uncopied.
      var aligner = FrameAligner()
      for try await chunk in body {
        let audio = aligner.align(chunk)
        if !audio.isEmpty { onAudio(audio) }
      }
    } catch let error as URLError where error.code == .timedOut {
      throw SpeechSynthesisError.timedOut
    } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
      // A stopped read cancels its request, which URLSession reports as an
      // error. It's a cancellation, and must read as one: a caller tells a
      // failure from a stop by it. Only when this task was cancelled, though
      // (`speech(for:)`'s `onTermination` cancels it when the read is
      // stopped): the same `URLError.cancelled` on a request nobody stopped is
      // one the system dropped, and a read cut short that way is a failure,
      // said as one.
      throw CancellationError()
    }
  }

  func request(for text: String, voiceID: String, apiKey: String) throws -> URLRequest {
    try URLRequest.jsonPost(
      to: Self.endpoint,
      apiKey: apiKey,
      userAgent: userAgent,
      timeout: Self.timeout,
      body: Body(text: text, voiceID: voiceID, sampleRate: Self.sampleRate, encoding: Self.encoding)
    )
  }
}
