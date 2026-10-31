import Foundation

/// AssemblyAI's realtime streaming API (v3) over a WebSocket: PCM in, turns
/// out — partial while a turn is being spoken, then final.
///
/// **The repo's one socket, and only for the main window's Record button.**
/// Dictation stays a single HTTP request that answers with one final transcript
/// (AGENTS.md's settled decisions, "No streaming STT"); this never carries a
/// dictation. A recording is a meeting or a call the user watches transcribe
/// as it happens, which is the one thing the realtime API is for.
/// `check-invariants.sh` exempts this file from the socket rule, and no other.
///
/// Everything sent and read is documented: the `/v3/ws` endpoint, the raw key
/// in `Authorization`, the `encoding`, `sample_rate` and `speaker_labels` query
/// parameters, binary audio of 50–1000 ms a message, the `Begin`, `Turn` and
/// `Termination` messages, and `{"type": "Terminate"}` to end. The speech
/// model is the endpoint's default.
public actor RealtimeTranscriber {
  public static let defaultURL = URL(literal: "wss://streaming.assemblyai.com/v3/ws")
  /// The sample rate of the PCM `send` takes — the recorder's output.
  public static let sampleRate = 16_000
  /// The smallest message `send` makes: 100 ms of 16-bit mono, inside the
  /// documented 50–1000 ms window. The recorder hands audio on in this size.
  public static let chunkBytes = sampleRate / 10 * 2
  /// The documented ceiling for one message — 1000 ms — which only the
  /// backlog queued before the socket opened can exceed.
  static let maximumChunkBytes = sampleRate * 2
  /// The documented floor for one message, which a final flush is padded to.
  static let minimumChunkBytes = sampleRate / 20 * 2
  /// How long `finish` waits for `Termination` before closing anyway.
  static let terminationTimeout: Duration = .seconds(10)

  /// The handshake request: internal so tests can read its query.
  nonisolated let request: URLRequest
  private let session: URLSession
  private var task: URLSessionWebSocketTask?
  private var pending = Data()
  private var continuation: AsyncThrowingStream<RealtimeTurn, any Error>.Continuation?
  private var terminated: CheckedContinuation<Void, Never>?
  private var didTerminate = false
  /// One decoder for every message: a partial arrives several times a second.
  private let decoder = JSONDecoder()

  public init(apiKey: String, url: URL = RealtimeTranscriber.defaultURL, userAgent: String? = nil) {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "encoding", value: "pcm_s16le"),
      URLQueryItem(name: "sample_rate", value: String(Self.sampleRate)),
      URLQueryItem(name: "speaker_labels", value: "true"),
    ]
    var request = URLRequest(url: components?.url ?? url)
    // The header, not the `token` query parameter: that is for browsers,
    // which can't set one.
    request.authorize(apiKey: apiKey, userAgent: userAgent)
    self.request = request
    self.session = URLSession(configuration: .default)
  }

  /// Opens the socket and returns every turn update as it arrives — a turn's
  /// partials, then its final. The stream ends after `Termination`, or throws
  /// if the connection fails.
  public func start() -> AsyncThrowingStream<RealtimeTurn, any Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: RealtimeTurn.self)
    self.continuation = continuation
    let task = session.webSocketTask(with: request)
    self.task = task
    task.resume()
    Task { await receive() }
    return stream
  }

  /// Queues recorded PCM (16 kHz mono S16LE) and sends it once 100 ms has
  /// gathered — whole, as any size in the documented window is valid, so the
  /// recorder's 100 ms hand-offs go out without being re-sliced.
  /// Audio that arrives before `start` has opened the socket waits here, so a
  /// recording's opening words aren't dropped while the connection comes up.
  public func send(_ pcm: Data) async {
    pending.append(pcm)
    guard task != nil else { return }
    while pending.count >= Self.chunkBytes {
      let chunk: Data
      if pending.count <= Self.maximumChunkBytes {
        chunk = pending
        pending = Data()
      } else {
        chunk = Data(pending.prefix(Self.maximumChunkBytes))
        pending.removeFirst(Self.maximumChunkBytes)
      }
      try? await task?.send(.data(chunk))
    }
  }

  /// Sends what's left, asks the service to end the session, and waits for
  /// `Termination` — which arrives after the last turn's final — then closes.
  public func finish() async {
    if !pending.isEmpty {
      var tail = pending
      if tail.count < Self.minimumChunkBytes {
        tail.append(Data(count: Self.minimumChunkBytes - tail.count))
      }
      pending.removeAll()
      try? await task?.send(.data(tail))
    }
    try? await task?.send(.string(#"{"type":"Terminate"}"#))
    // Bounded: a service that never answers must not leave the recording
    // stuck finishing. The timeout releases the wait itself.
    let timeout = Task {
      try? await Task.sleep(for: Self.terminationTimeout)
      self.releaseTerminationWait()
    }
    await waitForTermination()
    timeout.cancel()
    close(error: nil)
  }

  /// Drops the session at once, without waiting for the last turn.
  public func cancel() {
    close(error: nil)
  }

  private func releaseTerminationWait() {
    terminated?.resume()
    terminated = nil
  }

  private func waitForTermination() async {
    // Already closed (the socket failed, or `cancel`): no `Termination` is
    // coming, so don't sit out the timeout for one.
    guard !didTerminate, task != nil else { return }
    await withCheckedContinuation { terminated = $0 }
  }

  private func receive() async {
    while let task {
      let message: URLSessionWebSocketTask.Message
      do {
        message = try await task.receive()
      } catch {
        close(error: didTerminate ? nil : RealtimeError.connection(closeReason(of: task) ?? error.localizedDescription))
        return
      }
      guard case .string(let text) = message, let event = try? decoder.decode(Event.self, from: Data(text.utf8))
      else { continue }
      switch event.type {
      case "Turn":
        if let turn = event.turn { continuation?.yield(turn) }
      case "Termination":
        didTerminate = true
        releaseTerminationWait()
        continuation?.finish()
        continuation = nil
      default:
        continue
      }
    }
  }

  private func closeReason(of task: URLSessionWebSocketTask) -> String? {
    guard let reason = task.closeReason, let text = String(data: reason, encoding: .utf8), !text.isEmpty else {
      return nil
    }
    return text
  }

  private func close(error: (any Error)?) {
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
    // The session is this transcriber's alone; left valid, it leaks with it.
    session.finishTasksAndInvalidate()
    if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    continuation = nil
    releaseTerminationWait()
  }

  /// One server message — only the fields read. `Turn`'s are flattened into
  /// `turn`; `Begin` and anything else are ignored.
  struct Event: Decodable {
    let type: String
    let turn: RealtimeTurn?

    enum CodingKeys: String, CodingKey {
      case type
      case turnOrder = "turn_order"
      case transcript
      case endOfTurn = "end_of_turn"
      case speakerLabel = "speaker_label"
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      type = try container.decode(String.self, forKey: .type)
      guard type == "Turn" else {
        turn = nil
        return
      }
      turn = RealtimeTurn(
        order: try container.decode(Int.self, forKey: .turnOrder),
        transcript: try container.decodeIfPresent(String.self, forKey: .transcript) ?? "",
        isFinal: try container.decodeIfPresent(Bool.self, forKey: .endOfTurn) ?? false,
        speaker: try container.decodeIfPresent(String.self, forKey: .speakerLabel))
    }
  }
}

/// One turn as the realtime API last described it. A later update with the
/// same `order` replaces it — partials grow, then the final lands.
public struct RealtimeTurn: Sendable, Equatable {
  public let order: Int
  public let transcript: String
  /// `end_of_turn`: the speaker finished this turn and the text is settled.
  public let isFinal: Bool
  /// `speaker_label`, with speaker labels on: "A", "B", …
  public let speaker: String?

  public init(order: Int, transcript: String, isFinal: Bool, speaker: String?) {
    self.order = order
    self.transcript = transcript
    self.isFinal = isFinal
    self.speaker = speaker
  }
}

enum RealtimeError: Error, Equatable, LocalizedError {
  /// The socket failed or the service closed it, with its reason.
  case connection(String)

  var errorDescription: String? {
    switch self {
    case .connection(let reason): "The live transcription stopped: \(reason)"
    }
  }
}
