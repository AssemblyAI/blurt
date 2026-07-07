import Foundation
import os

/// Latency instrumentation for the Sync round-trip. Findable via:
///   log show --predicate 'subsystem == "dev.alex.blurt" && category == "Transcriber"' --last 1h
/// File-scoped so both `send(_:body:audioDurationMs:)` (wall-clock) and
/// `MetricsLogger` (the DNS/TCP/TLS/TTFB split) can write to it.
private let transcriberLog = Logger(subsystem: BlurtIdentity.subsystem, category: "Transcriber")

/// `TranscriberProtocol` backed by AssemblyAI's **Sync** Speech-to-Text API.
///
/// Mirrors the endpoint used by the `assembly dictate` CLI command: a single
/// `POST sync.assemblyai.com/transcribe` carries the captured audio (raw S16LE
/// PCM) plus a JSON `config` part, and the finished transcript comes back in the
/// response body. No upload step, no job submission, no polling — one request
/// per utterance. The Universal-3 sync model (`u3-sync-pro`) handles audio from
/// ~80 ms up to 120 s with a server-side inference deadline of ~30 s.
public struct AssemblyAITranscriber: TranscriberProtocol {
  private let apiKeyProvider: @Sendable () -> String?
  private let baseURL: URL
  private let transport: any HTTPTransport

  /// Required on every Sync API request — selects the synchronous STT model.
  private static let syncModel = "u3-sync-pro"

  public init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.get() },
    baseURL: URL = URL(string: "https://sync.assemblyai.com")!,
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.baseURL = baseURL
    self.transport = transport
  }

  // MARK: - Sync request

  public func transcribe(
    samples: [Float], sampleRate: Int, context: TranscriptionContext?
  ) async throws -> String {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      throw BlurtError.apiKeyMissing
    }
    let pcm = PCMEncoder.encodeS16LE(samples: samples)
    let prompt = TranscriptionPrompt.build(context: context)
    let config = try makeConfigData(sampleRate: sampleRate, prompt: prompt)
    let boundary = "blurt-\(UUID().uuidString)"

    var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue(Self.syncModel, forHTTPHeaderField: "X-AAI-Model")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let body = multipartBody(pcm: pcm, config: config, boundary: boundary)
    let audioDurationMs = Int((Double(samples.count) / Double(sampleRate)) * 1000)
    let data = try await send(request, body: body, audioDurationMs: audioDurationMs)
    guard let response = try? JSONDecoder().decode(SyncTranscriptResponse.self, from: data) else {
      throw AssemblyAIError.malformedResponse
    }
    return response.text
  }

  /// Pre-open and pool a connection to the Sync host so the next `transcribe`
  /// reuses it instead of paying DNS+TCP+TLS on the hot path (~170 ms cold, more
  /// on mobile — measured). A throwaway GET to the host root is enough to
  /// establish the HTTP/2 connection `URLSession` then reuses for the POST to
  /// `/transcribe`; the response (an auth-less 4xx) is discarded. No `X-AAI-Model`
  /// or key, so it never reaches the model or counts as a transcription. A short
  /// timeout keeps a dead network from leaving the task hanging. Fire-and-forget:
  /// any error is swallowed, since the real request degrades to the old behavior.
  public func warmUp() async {
    var request = URLRequest(url: baseURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 5
    let clock = ContinuousClock()
    let start = clock.now
    _ = try? await transport.data(for: request)
    let ms = (clock.now - start).milliseconds
    transcriberLog.info("warm-up connect \(ms, format: .fixed(precision: 0), privacy: .public)ms")
  }

  /// Builds the JSON `config` part sent alongside the audio. The context
  /// `prompt` is included only when non-empty; a nil or blank prompt omits the
  /// field so the server applies its default prompt. Internal so tests can
  /// assert the prompt wiring without inspecting the multipart upload body
  /// (which `URLProtocol` mocks can't observe reliably for `upload(from:)`).
  func makeConfigData(sampleRate: Int, prompt: String?) throws -> Data {
    try JSONEncoder().encode(
      SyncConfig(
        sampleRate: sampleRate,
        channels: 1,
        prompt: prompt.trimmedNonEmpty()
      )
    )
  }

  /// Builds the `audio` (raw PCM) + `config` (JSON) multipart payload the Sync
  /// API expects, matching the field names `assembly dictate` sends.
  private func multipartBody(pcm: Data, config: Data, boundary: String) -> Data {
    var body = Data()
    // Reserve up front (payload + a generous allowance for the boundary/header
    // framing) so appending the multi-MB PCM blob never grows the buffer through
    // reallocation copies.
    body.reserveCapacity(pcm.count + config.count + 512)
    func append(_ string: String) { body.append(Data(string.utf8)) }

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n")
    append("Content-Type: audio/pcm\r\n\r\n")
    body.append(pcm)
    append("\r\n")

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"config\"\r\n")
    append("Content-Type: application/json\r\n\r\n")
    body.append(config)
    append("\r\n")

    append("--\(boundary)--\r\n")
    return body
  }

  // MARK: - Networking helpers

  private func send(_ request: URLRequest, body: Data, audioDurationMs: Int) async throws -> Data {
    // Per-task delegate (not a session delegate) so this rides along on whatever
    // transport was injected — `URLSession.shared` in production, a fake in
    // tests — without reconfiguring it. `MetricsLogger` logs the connect-vs-
    // inference split; the wall-clock line below is the always-available total.
    let metrics = MetricsLogger(audioDurationMs: audioDurationMs)
    let clock = ContinuousClock()
    let start = clock.now
    let (data, response) = try await transport.upload(for: request, from: body, delegate: metrics)
    let wallMs = (clock.now - start).milliseconds
    transcriberLog.info(
      "sync round-trip audioMs=\(audioDurationMs, privacy: .public) wallMs=\(wallMs, format: .fixed(precision: 0), privacy: .public)"
    )
    guard let http = response as? HTTPURLResponse else { return data }
    guard (200..<300).contains(http.statusCode) else {
      throw AssemblyAIError.http(status: http.statusCode, message: Self.errorMessage(from: data))
    }
    return data
  }

  /// Best human-readable explanation for a non-2xx response. The Sync API isn't
  /// consistent about the field name across error classes (`error`, `message`,
  /// and `detail` have all been seen), so try each; failing that, fall back to
  /// the raw body text (trimmed and capped) so a failure never reaches the user
  /// as a bare status code with no context. Returns nil only for an empty body.
  static func errorMessage(from data: Data) -> String? {
    if let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data),
      let message = parsed.message
    {
      return message
    }
    guard let raw = String(bytes: data, encoding: .utf8).trimmedNonEmpty() else { return nil }
    return String(raw.prefix(500))
  }

  // MARK: - Wire types

  private struct SyncConfig: Encodable {
    let sampleRate: Int
    let channels: Int
    /// Custom transcription instruction. Encoded only when non-nil (the
    /// synthesized `encode` uses `encodeIfPresent` for optionals), so omitting
    /// it falls back to the server's default prompt.
    let prompt: String?
    enum CodingKeys: String, CodingKey {
      case sampleRate = "sample_rate"
      case channels
      case prompt
    }
  }

  private struct SyncTranscriptResponse: Decodable {
    let text: String
  }

  /// A Sync API failure body. The endpoint labels the explanation differently
  /// across error classes, so pull it from whichever of `error` / `message` /
  /// `detail` is present and string-valued (a non-string `detail`, e.g. FastAPI's
  /// validation array, is ignored — the caller then falls back to the raw body).
  private struct ErrorResponse: Decodable {
    let message: String?

    enum CodingKeys: String, CodingKey {
      case error, message, detail
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      func string(_ key: CodingKeys) -> String? {
        (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
      }
      message = string(.error) ?? string(.message) ?? string(.detail)
    }
  }
}

/// Per-request `URLSessionTaskDelegate` that logs the Sync round-trip's latency
/// breakdown from `URLSessionTaskMetrics`: how much was connection setup
/// (DNS/TCP/TLS — warmable by pre-connecting at record-start) versus server
/// inference (`ttfbMs` ≈ requestStart→responseStart). `reused=true` means the
/// pooled connection was hot, so setup was ~free. Best-effort: any timestamp the
/// transport doesn't report is logged as `n/a`. Holds only immutable state, so
/// `@unchecked Sendable` is sound for the delegate-queue callback.
private final class MetricsLogger: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let audioDurationMs: Int
  init(audioDurationMs: Int) { self.audioDurationMs = audioDurationMs }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    guard let t = metrics.transactionMetrics.last else { return }
    func ms(_ from: Date?, _ to: Date?) -> String {
      guard let from, let to else { return "n/a" }
      return String(format: "%.0f", to.timeIntervalSince(from) * 1000)
    }
    transcriberLog.info(
      """
      sync metrics audioMs=\(self.audioDurationMs, privacy: .public) \
      reused=\(t.isReusedConnection, privacy: .public) \
      dnsMs=\(ms(t.domainLookupStartDate, t.domainLookupEndDate), privacy: .public) \
      connectMs=\(ms(t.connectStartDate, t.connectEndDate), privacy: .public) \
      tlsMs=\(ms(t.secureConnectionStartDate, t.secureConnectionEndDate), privacy: .public) \
      ttfbMs=\(ms(t.requestStartDate, t.responseStartDate), privacy: .public) \
      totalMs=\(ms(t.fetchStartDate, t.responseEndDate), privacy: .public)
      """
    )
  }
}

extension Duration {
  /// This duration in milliseconds as a Double (for latency logging).
  fileprivate var milliseconds: Double {
    let c = components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1_000_000_000_000_000
  }
}

/// Errors specific to the AssemblyAI transport. These get wrapped in
/// `BlurtError.sttFailed` before reaching the UI.
enum AssemblyAIError: Error, LocalizedError {
  case http(status: Int, message: String?)
  case malformedResponse

  var errorDescription: String? {
    switch self {
    case .http(let status, let message):
      if let message { return "AssemblyAI error \(status): \(message)" }
      return "AssemblyAI error \(status)"
    case .malformedResponse:
      return "Unexpected response from AssemblyAI."
    }
  }
}
