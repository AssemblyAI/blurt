import Foundation
import Synchronization

/// Streams speech for a piece of text from AssemblyAI's streaming TTS, as raw
/// PCM16 little-endian mono at `sampleRate`. Powers the experimental
/// read-selection-aloud press (`SelectionSpeaker`, `SelectionSpeechStore`).
///
/// **This endpoint is undocumented.** AssemblyAI's public docs say it offers no
/// standalone TTS, so everything here comes from the AssemblyAI agent runtime's
/// adapter (`aai-runtime/src/providers/tts/assemblyai.ts`), which read it back
/// from the live service. That is why the feature sits behind an experimental
/// switch instead of following the dictation API's docs-are-the-contract rule.
/// (It is also the one file `check-invariants.sh` lets hold a WebSocket.)
///
/// The protocol:
/// - **Connect** to `endpoint` with `voice` and `sample_rate` query params. Authenticate
///   with the **raw** API key in `Authorization` — not `Bearer <key>`. A bad key
///   still completes the upgrade, then comes back in-band as an `Error` frame.
/// - **Send** `{"type":"Generate","text":…}` followed by `{"type":"Flush"}` for
///   each segment. `Generate` alone only buffers text: no audio is produced
///   until a `Flush`. See `SpeechSegmenter` for where the cuts go.
/// - **Receive** `Audio` frames (base64 PCM16), then one `FlushDone` for each
///   flush. The text has been spoken once every flush is acknowledged.
///   `WordBoundaries` frames are timing data, not acknowledgements, and a
///   `Begin` frame may or may not arrive, so don't wait for it.
/// - **Close** with `{"type":"Terminate"}`.
struct AssemblyAISpeechSynthesizer: Sendable {
  static let sampleRate = 24_000
  static let voice = "jane"
  static let endpoint = URL(staticString: "wss://streaming-tts.assemblyai.com/v1/ws/")

  private let apiKeyProvider: @Sendable () -> String?
  private let connect: @Sendable (URLRequest) -> any SpeechSocket
  /// How long the socket may go silent before the read is abandoned. A stalled
  /// server, or a flush that is never acknowledged, would otherwise leave the
  /// press in read-aloud mode, silent, until the next tap ended it. Real frames
  /// land within about a second of each flush.
  private let receiveTimeout: Duration

  /// `connect` is the socket seam: production opens a `URLSessionWebSocketTask`,
  /// and the tests script the service's side of the exchange.
  init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    receiveTimeout: Duration = .seconds(10),
    connect: @escaping @Sendable (URLRequest) -> any SpeechSocket = { request in
      let socket = URLSession.shared.webSocketTask(with: request)
      socket.resume()
      return socket
    }
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.receiveTimeout = receiveTimeout
    self.connect = connect
  }

  /// PCM chunks in playback order. The stream finishes once the service has
  /// acknowledged every segment. Cancelling the consumer closes the socket.
  func synthesize(_ text: String) -> AsyncThrowingStream<Data, Error> {
    let segments = SpeechSegmenter.segments(of: text)
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await run(segments: segments) { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static let url = endpoint.appending(queryItems: [
    URLQueryItem(name: "voice", value: voice),
    URLQueryItem(name: "sample_rate", value: String(sampleRate)),
  ])

  private func run(segments: [String], onAudio: @escaping @Sendable (Data) -> Void) async throws {
    guard !segments.isEmpty else { return }
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { throw BlurtError.apiKeyMissing }
    var request = URLRequest(url: Self.url)
    // Raw key, not `Bearer` — see the type doc.
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setUserAgent()
    let socket = connect(request)
    try await withTaskCancellationHandler {
      // `exchange` closes the socket itself on every failure.
      try await exchange(over: socket, segments: segments, onAudio: onAudio)
      try? await socket.send(Self.command("Terminate"))
      socket.close(normally: true)
    } onCancel: {
      socket.close(normally: false)
    }
  }

  private func exchange(
    over socket: any SpeechSocket, segments: [String], onAudio: @escaping @Sendable (Data) -> Void
  ) async throws {
    let watchdog = Watchdog(timeout: receiveTimeout)
    try await withThrowingTaskGroup(of: Void.self) { group in
      // Sending runs beside the receive loop rather than ahead of it. A
      // rejected key is reported in a frame, and the receive loop is what
      // turns that frame into a readable error. A send failing first would
      // only say the socket closed.
      group.addTask {
        for segment in segments {
          // Each segment is billed synthesis. Once the read has failed or been
          // stopped, don't queue any more.
          try Task.checkCancellation()
          try await socket.send(Self.command("Generate", text: segment))
          try await socket.send(Self.command("Flush"))
        }
      }
      // One idle timer for the whole exchange. A closed socket is the only
      // thing that ends a pending receive, so the timer closes it.
      group.addTask {
        try await watchdog.run { socket.close(normally: false) }
      }
      do {
        var acknowledged = 0
        while acknowledged < segments.count {
          let message = try await socket.receive()
          watchdog.heard()
          switch Self.frame(from: message) {
          case .audio(let pcm): onAudio(pcm)
          case .flushDone: acknowledged += 1
          case .error(let message): throw SpeechSynthesisError.server(message)
          case .ignored: break
          }
        }
      } catch {
        // Close *before* leaving the group. The group waits for the sender on
        // the way out, and a socket send doesn't observe cancellation, so only
        // a closed socket makes a pending send fail rather than finish.
        socket.close(normally: false)
        throw watchdog.expired ? SpeechSynthesisError.timedOut : error
      }
      group.cancelAll()
    }
  }

  // MARK: - Wire format

  enum Frame: Equatable {
    case audio(Data)
    case flushDone
    case error(String)
    /// `Begin`, `Warning`, `WordBoundaries`, `Cancelled`, and anything newer.
    case ignored
  }

  private struct Command: Encodable {
    let type: String
    let text: String?
  }

  static func command(_ type: String, text: String? = nil) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    // Encoding two strings to UTF-8 JSON can't fail.
    guard let data = try? encoder.encode(Command(type: type, text: text)) else { return "" }
    return String(bytes: data, encoding: .utf8) ?? ""
  }

  static func frame(from message: URLSessionWebSocketTask.Message) -> Frame {
    let data: Data
    switch message {
    case .string(let text): data = Data(text.utf8)
    case .data(let bytes): data = bytes
    @unknown default: return .ignored
    }
    return frame(from: data)
  }

  /// Decodes one server frame leniently: anything that isn't a JSON object with
  /// a known `type` is `.ignored`, not an error. `error_code` may be a number or
  /// a string, depending on the server version.
  static func frame(from data: Data) -> Frame {
    guard
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let type = object["type"] as? String
    else { return .ignored }
    switch type {
    case "Audio":
      guard let base64 = object["audio"] as? String, let pcm = Data(base64Encoded: base64), !pcm.isEmpty
      else { return .ignored }
      return .audio(pcm)
    case "FlushDone":
      return .flushDone
    case "Error":
      let reason = (object["error"] as? String)?.trimmedNonEmpty() ?? "unknown error"
      if let code = object["error_code"] { return .error("(\(code)) \(reason)") }
      return .error(reason)
    default:
      return .ignored
    }
  }
}

enum SpeechSynthesisError: Error, Equatable, LocalizedError {
  /// The socket went silent for longer than the synthesizer's receive timeout.
  case timedOut
  /// An in-band `Error` frame, e.g. `(1008) Unauthorized: Invalid API key`.
  case server(String)

  var errorDescription: String? {
    switch self {
    case .timedOut: "Text-to-speech stopped responding."
    case .server(let message): "Text-to-speech failed: \(message)"
    }
  }
}

/// Idle timer for one exchange: `run` closes the socket once `timeout` passes
/// with no `heard()`, and records that it did so, so the receive loop can report
/// a timeout rather than the closed socket it causes.
private final class Watchdog: Sendable {
  private struct State {
    var lastHeard = ContinuousClock.now
    var expired = false
  }

  private let timeout: Duration
  private let state = Mutex(State())

  init(timeout: Duration) { self.timeout = timeout }

  var expired: Bool { state.withLock(\.expired) }

  func heard() { state.withLock { $0.lastHeard = .now } }

  func run(onExpiry close: () -> Void) async throws {
    while true {
      let deadline = state.withLock { $0.lastHeard } + timeout
      guard ContinuousClock.now < deadline else { break }
      try await Task.sleep(until: deadline)
    }
    state.withLock { $0.expired = true }
    close()
  }
}

/// The socket operations the synthesizer uses, so the tests can play the
/// service's side. `URLSessionWebSocketTask` is the production conformance.
protocol SpeechSocket: Sendable {
  func send(_ text: String) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  /// Closes the socket: normally after `Terminate`, abruptly on failure or
  /// cancel. Synchronous, because a cancellation handler can't await.
  func close(normally: Bool)
}

extension URLSessionWebSocketTask: SpeechSocket {
  func send(_ text: String) async throws {
    try await send(.string(text))
  }

  func close(normally: Bool) {
    cancel(with: normally ? .normalClosure : .goingAway, reason: nil)
  }
}
