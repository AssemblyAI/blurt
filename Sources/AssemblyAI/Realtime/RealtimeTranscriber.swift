public import Foundation

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
public actor RealtimeTranscriber: LiveTranscriptionSession {
  private enum Phase {
    case idle, open, closed
  }

  /// One server message — only the fields read. `Turn`'s are flattened into
  /// `turn`; `Begin` and anything else are ignored.
  struct Event: Decodable {
    enum CodingKeys: String, CodingKey {
      case type
      case turnOrder = "turn_order"
      case transcript
      case endOfTurn = "end_of_turn"
      case speakerLabel = "speaker_label"
    }

    let type: String
    let turn: RealtimeTurn?

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
        speaker: try container.decodeIfPresent(String.self, forKey: .speakerLabel)
      )
    }
  }

  /// The documented Universal-Streaming endpoint, which `init` defaults to.
  public static let defaultURL = URL(literal: "wss://streaming.assemblyai.com/v3/ws")
  /// The sample rate of the PCM `send` takes — the recorder's output.
  public static let sampleRate = 16_000
  /// The smallest message `send` makes: 100 ms of 16-bit mono, inside the
  /// documented 50–1000 ms window. The recorder hands audio on in this size.
  public static let chunkBytes = sampleRate / 10 * 2
  /// The documented ceiling for one message — 1000 ms. The backlog queued
  /// before the socket opened can be longer, so it is sliced to this.
  static let maximumChunkBytes = sampleRate * 2
  /// The documented floor for one message, which a final flush is padded to.
  static let minimumChunkBytes = sampleRate / 20 * 2
  /// How long `finish` waits for `Termination` before closing anyway.
  static let terminationTimeout: Duration = .seconds(10)

  /// The handshake request: internal so tests can read its query.
  nonisolated let request: URLRequest
  private let session: URLSession
  private var task: URLSessionWebSocketTask?
  /// Where the session is in its one pass through life. `closed` is final:
  /// the `URLSession` is invalidated by then, and asking it for a socket
  /// raises — so a `start` that loses a race with `cancel` (the recording's
  /// tasks are unstructured) must find it here and open nothing.
  private var phase = Phase.idle
  /// Audio not yet sent. Readable by tests, which check nothing is queued for
  /// a session that has closed.
  private(set) var pending = Data()
  private var continuation: AsyncThrowingStream<RealtimeTurn, any Error>.Continuation?
  /// Every `finish` waiting for `Termination` — a list, not one slot, so a
  /// second caller can't overwrite (and so strand) the first.
  private var terminationWaiters: [CheckedContinuation<Void, Never>] = []
  private var isFinishing = false
  private var didTerminate = false
  /// One decoder for every message: a partial arrives several times a second.
  private let decoder = JSONDecoder()

  /// A transcriber that will authenticate with `apiKey` against `url`; nothing
  /// connects until `start`.
  public init(apiKey: String, url: URL = RealtimeTranscriber.defaultURL, userAgent: String? = nil) {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "encoding", value: "pcm_s16le"),
      URLQueryItem(name: "sample_rate", value: String(Self.sampleRate)),
      URLQueryItem(name: "speaker_labels", value: "true"),
    ]
    var handshake = URLRequest(url: components?.url ?? url)
    // The header, not the `token` query parameter: that is for browsers,
    // which can't set one.
    handshake.authorize(apiKey: apiKey, userAgent: userAgent)
    self.request = handshake
    self.session = URLSession(configuration: .default)
  }

  /// Opens the socket and returns every turn update as it arrives — a turn's
  /// partials, then its final. The stream ends after `Termination`, or throws
  /// if the connection fails. Once the session has closed — `cancel` or
  /// `finish` got here first — the stream is already over and nothing opens.
  public func start() -> AsyncThrowingStream<RealtimeTurn, any Error> {
    let (stream, turns) = AsyncThrowingStream.makeStream(of: RealtimeTurn.self)
    guard phase == .idle else {
      turns.finish()
      return stream
    }
    phase = .open
    self.continuation = turns
    let socket = session.webSocketTask(with: request)
    self.task = socket
    socket.resume()
    Task { await receive() }
    return stream
  }

  /// Queues recorded PCM (16 kHz mono S16LE) and sends it once 100 ms has
  /// gathered — whole, as any size in the documented window is valid, so the
  /// recorder's 100 ms hand-offs go out without being re-sliced.
  /// Audio that arrives before `start` has opened the socket waits here, so a
  /// recording's opening words aren't dropped while the connection comes up.
  /// Once the session is finishing or closed, audio is dropped rather than
  /// sent after `Terminate` or queued for a socket that will never take it.
  public func send(_ pcm: Data) async {
    guard phase != .closed, !isFinishing else {
      return
    }
    pending.append(pcm)
    guard phase == .open else {
      return
    }
    await drainPending(final: false)
  }

  /// Sends what's left, asks the service to end the session, and waits for
  /// `Termination` — which arrives after the last turn's final — then closes.
  /// A session that never opened just closes, dropping any audio queued for
  /// it — so a caller that has `start` in flight awaits it first; a second
  /// caller waits on the first's `Termination` rather than asking again.
  public func finish() async {
    guard phase == .open else {
      close(error: nil)
      return
    }
    guard !isFinishing else {
      await waitForTermination()
      return
    }
    isFinishing = true
    await drainPending(final: true)
    await transmit(.string(#"{"type":"Terminate"}"#))
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

  /// Sends the queue in messages of at most `maximumChunkBytes`: whole while
  /// it fits, as any size in the documented window is valid, so the
  /// recorder's 100 ms hand-offs go out without being re-sliced. Below
  /// `chunkBytes` the rest waits for more — unless `final`, when it goes too,
  /// padded with silence to the 50 ms floor and to a whole sample.
  private func drainPending(final: Bool) async {
    while pending.count >= Self.chunkBytes || (final && !pending.isEmpty) {
      var chunk: Data
      if pending.count <= Self.maximumChunkBytes {
        chunk = pending
        pending = Data()
      } else {
        chunk = Data(pending.prefix(Self.maximumChunkBytes))
        pending.removeFirst(Self.maximumChunkBytes)
      }
      if chunk.count < Self.minimumChunkBytes {
        chunk.append(Data(count: Self.minimumChunkBytes - chunk.count))
      } else if final, pending.isEmpty, !chunk.count.isMultiple(of: 2) {
        chunk.append(0)
      }
      await transmit(.data(chunk))
    }
  }

  /// Sends one message, dropping a send error: a broken socket surfaces
  /// through `receive()`, which closes the session with the reason.
  /// The completion handler, not the async `send(_:)`, for the same
  /// ThreadSanitizer report `receive()` avoids.
  private func transmit(_ message: URLSessionWebSocketTask.Message) async {
    guard let task else {
      return
    }
    await withCheckedContinuation { continuation in
      task.send(message) { _ in continuation.resume() }
    }
  }

  private func releaseTerminationWait() {
    let waiters = terminationWaiters
    terminationWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func waitForTermination() async {
    // Already closed (the socket failed, or `cancel`): no `Termination` is
    // coming, so don't sit out the timeout for one.
    guard !didTerminate, task != nil else {
      return
    }
    await withCheckedContinuation { terminationWaiters.append($0) }
  }

  private func receive() async {
    while let task {
      let message: URLSessionWebSocketTask.Message
      do {
        // The completion handler under a checked continuation, not the async
        // `receive()`: that bridge's result slot is written on one GCD thread
        // and read on another, which ThreadSanitizer reports as a data race
        // (seen on CI, intermittently).
        message = try await withCheckedThrowingContinuation { continuation in
          task.receive { continuation.resume(with: $0) }
        }
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
    phase = .closed
    pending = Data()
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
    // The session is this transcriber's alone; left valid, it leaks with it.
    session.finishTasksAndInvalidate()
    if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    continuation = nil
    releaseTerminationWait()
  }

  /// A transcriber dropped without `finish` or `cancel` — the recorder failed
  /// to start, say — still releases its session, which would otherwise leak.
  deinit {
    session.invalidateAndCancel()
  }
}
