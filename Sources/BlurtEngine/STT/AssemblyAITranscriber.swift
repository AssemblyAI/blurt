import Foundation
import os

/// Latency instrumentation for the dictation round-trip. Findable via:
///   log show --predicate 'subsystem == "dev.alex.blurt" && category == "Transcriber"' --last 1h
/// File-scoped so both `send(_:body:audioDurationMs:)` (wall-clock) and
/// `MetricsLogger` (the DNS/TCP/TLS/TTFB split) can write to it.
private let transcriberLog = Logger(subsystem: BlurtIdentity.subsystem, category: "Transcriber")

/// `TranscriberProtocol` backed by AssemblyAI's **dictation** API.
///
/// A single `POST dictation.assemblyai.com/transcribe` carries the captured
/// audio (raw S16LE PCM, exactly the bytes the mic recorded — there is no
/// re-encoding pass) plus a JSON `config` part, and the response body carries
/// both the verbatim transcript and — when the config requests one via its
/// `llm` block (the "enhanced transcripts" setting, on by default) — an
/// LLM-rewritten version with disfluencies removed, produced by applying
/// `CleanupInstruction.text` server-side.
/// No upload step, no job submission, no polling — one
/// request per utterance covers transcription *and* cleanup. The service picks
/// the STT model server-side and handles audio from ~80 ms up to 120 s; the
/// rewrite is best-effort with a ~5 s server-side deadline, so a rewrite
/// failure still returns the verbatim transcript (`llm_response` null).
public struct AssemblyAITranscriber: TranscriberProtocol {
  private let apiKeyProvider: @Sendable () -> String?
  private let baseURL: URL
  private let transport: any HTTPTransport
  private let enhancedTranscriptsEnabled: @Sendable () -> Bool
  private let customStyle: @Sendable () -> String?

  /// Idle timeout for the transcribe round trip — `URLRequest.timeoutInterval` is
  /// reset each time data moves, so this bounds *stalls*, not total elapsed time.
  /// 90 s is the client timeout the dictation API documents: generous over the
  /// STT upstream's ~30 s inference deadline plus the rewrite's 5 s budget, so
  /// the server — not the client — decides when a slow request has failed,
  /// while a connection that stops delivering bytes still can't leave the pill
  /// stuck on "Transcribing…" indefinitely.
  private static let requestTimeoutSeconds: TimeInterval = 90

  /// `enhancedTranscripts` decides, per request, whether the config carries
  /// the `llm` cleanup-rewrite block; `customStyle` supplies the user's custom
  /// style instructions appended to that block's cleanup instruction. Both are
  /// read at every `transcribe` so a settings change applies to the next
  /// dictation without rebuilding the transcriber. `nil` (the default) reads
  /// the corresponding store — spelled as optionals rather than default
  /// closures because a public default argument can't reference a store's
  /// internal member.
  public init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    baseURL: URL = URL(staticString: "https://dictation.assemblyai.com"),
    transport: any HTTPTransport = URLSession.shared,
    enhancedTranscripts: (@Sendable () -> Bool)? = nil,
    customStyle: (@Sendable () -> String?)? = nil
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.baseURL = baseURL
    self.transport = transport
    self.enhancedTranscriptsEnabled = enhancedTranscripts ?? { EnhancedTranscriptsStore().isEnabled }
    self.customStyle = customStyle ?? { CustomStyleStore().instructions }
  }

  // MARK: - Dictation request

  public func transcribe(
    pcm: Data, sampleRate: Int, context: TranscriptionContext?
  ) async throws -> String {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      throw BlurtError.apiKeyMissing
    }
    // The prior dialogue that goes on the wire: the user's recent dictations,
    // then the text before the cursor (empty when there is neither, which omits
    // the field). App name, window title, field label and selected text stay on
    // the machine — `ConversationContext` draws that line, so nothing is
    // filtered here.
    let conversation = ConversationContext.turns(context: context)
    // The other steering field: the user's key terms as a word-boost list,
    // fitted to its own (different) cap.
    let boost = KeytermsBoost.fitted(context?.keyTerms ?? [])
    let config = try makeConfigData(
      sampleRate: sampleRate, conversationContext: conversation, wordBoost: boost)
    let boundary = "blurt-\(UUID().uuidString)"

    var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
    request.httpMethod = "POST"
    // Bounds a stalled connection; see `requestTimeoutSeconds` for why an idle
    // timeout is the right shape here.
    request.timeoutInterval = Self.requestTimeoutSeconds
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let body = multipartBody(pcm: pcm, config: config, boundary: boundary)
    let audioDurationMs = SyncSTTLimits.durationMs(ofPCMBytes: pcm.count, rate: sampleRate)
    let data = try await send(request, body: body, audioDurationMs: audioDurationMs)
    guard let response = try? JSONDecoder().decode(DictationResponse.self, from: data) else {
      throw AssemblyAIError.malformedResponse
    }
    // The rewrite is best-effort, so anything unusable degrades to the verbatim
    // transcript rather than an error. Blank counts as unusable alongside null:
    // the service is documented to null out an empty rewrite, but a "" slipping
    // through would strand the utterance — the pipeline drops a whitespace-only
    // transcript to `.idle` without pasting or reporting, wasting the good
    // verbatim `text` right below it.
    if let rewrite = response.llmResponse.trimmedNonEmpty() { return rewrite }
    if let error = response.llmError {
      transcriberLog.warning(
        "llm rewrite unavailable (\(error, privacy: .public)); using verbatim transcript")
    }
    return response.text
  }

  /// Pre-open and pool a connection to the dictation host so the next
  /// `transcribe` reuses it instead of paying DNS+TCP+TLS on the hot path
  /// (~170 ms cold, more on mobile — measured). A throwaway GET to the host
  /// root is enough to establish the HTTP/2 connection `URLSession` then reuses
  /// for the POST to `/transcribe`; the response (an auth-less 4xx) is
  /// discarded. No key, so it never counts as a transcription. A short timeout
  /// keeps a dead network from leaving the task hanging. Fire-and-forget: any
  /// error is swallowed — a failed warm-up just means the next request pays
  /// connection setup itself.
  public func warmUp() async {
    var request = URLRequest(url: baseURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 5
    let clock = ContinuousClock()
    let start = clock.now
    _ = try? await transport.data(for: request)
    let elapsedMs = (clock.now - start).milliseconds
    transcriberLog.info(
      "warm-up connect \(elapsedMs, format: .fixed(precision: 0), privacy: .public)ms")
  }

  /// Builds the JSON `config` part sent alongside the audio. Both steering
  /// fields are included only when non-empty: an empty `conversationContext`
  /// omits `conversation_context` (no prior dialogue, so the model works from the
  /// audio alone) and an empty `wordBoost` omits `word_boost` (which would
  /// otherwise ask to boost nothing). There is no `prompt` — see
  /// `ConversationContext` for why the service's managed default is what steers
  /// transcription now. The `llm` block rides
  /// along while enhanced transcripts are enabled (the default) and is omitted
  /// entirely when the user has turned them off, so the service skips the
  /// rewrite and the verbatim transcript is what gets pasted — see
  /// `DictationConfig.llm`. Internal so tests can assert the
  /// config wiring without inspecting the multipart upload body (which
  /// `URLProtocol` mocks can't observe reliably for `upload(from:)`).
  /// Neither steering field is defaulted: every caller states both, so what a
  /// given request does and does not steer with is readable at the call site
  /// rather than inferred from which argument was left off.
  func makeConfigData(
    sampleRate: Int, conversationContext: [String], wordBoost: [String]
  ) throws -> Data {
    let enhanced = enhancedTranscriptsEnabled()
    let instruction = enhanced ? CleanupInstruction.sendable(appending: customStyle()) : nil
    if enhanced, instruction == nil {
      // Unreachable while the tests run: `CleanupInstructionTests` asserts the length.
      // Logged rather than trusted because the failure it guards against is silent —
      // the request would 400 and every dictation would error, so a line naming the
      // real cause is worth the one comparison per request it costs.
      transcriberLog.error(
        """
        cleanup instruction is \(CleanupInstruction.text.utf8.count, privacy: .public) UTF-8 bytes, \
        over the \(CleanupInstruction.characterCap, privacy: .public) cap; \
        falling back to the service default
        """)
    }
    return try JSONEncoder().encode(
      DictationConfig(
        sampleRate: sampleRate,
        channels: 1,
        conversationContext: conversationContext,
        wordBoost: wordBoost,
        llm: enhanced ? LLMRewrite(instruction: instruction) : nil
      )
    )
  }

  /// Builds the `audio` (raw PCM) + `config` (JSON) multipart payload the
  /// dictation API expects.
  ///
  /// Internal, not private, so tests can assert the framing against the bytes.
  /// `FakeHTTPTransport` can't: `URLProtocol`-style mocks don't reliably observe
  /// the body of an `upload(from:)`, which left the wire format — boundaries, part
  /// headers, the `audio.pcm` filename, CRLF placement — checked by nothing.
  func multipartBody(pcm: Data, config: Data, boundary: String) -> Data {
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
      "dictation round-trip audioMs=\(audioDurationMs, privacy: .public) wallMs=\(wallMs, format: .fixed(precision: 0), privacy: .public)"
    )
    guard let http = response as? HTTPURLResponse else { return data }
    guard (200..<300).contains(http.statusCode) else {
      throw AssemblyAIError.http(status: http.statusCode, message: Self.errorMessage(from: data))
    }
    return data
  }

  /// Best human-readable explanation for a non-2xx response: `message`, then
  /// `detail` (the two documented shapes — see `ErrorResponse`), then the raw body
  /// text, trimmed and capped.
  ///
  /// The raw-body arm is deliberately kept. It is not compatibility with an old
  /// API shape — it is what turns a response the API never promised (a proxy's HTML
  /// 502, a captive-portal page) into something diagnosable instead of a bare
  /// status code. Returns nil only for an empty body.
  static func errorMessage(from data: Data) -> String? {
    if let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data),
      let message = parsed.message
    {
      return message
    }
    guard let raw = String(bytes: data, encoding: .utf8).trimmedNonEmpty() else { return nil }
    return String(raw.prefix(500))
  }

  // The request/response types this encodes and decodes — `DictationConfig`,
  // `LLMRewrite`, `DictationResponse`, `ErrorResponse` — live in
  // `DictationWireTypes.swift`, split out to stay within the lint file-length
  // budget. They are the JSON contract; everything here is the transport.
}

/// Per-request `URLSessionTaskDelegate` that logs the dictation round-trip's latency
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
    guard let transaction = metrics.transactionMetrics.last else { return }
    func ms(_ from: Date?, _ to: Date?) -> String {
      guard let from, let to else { return "n/a" }
      return String(format: "%.0f", to.timeIntervalSince(from) * 1000)
    }
    transcriberLog.info(
      """
      dictation metrics audioMs=\(self.audioDurationMs, privacy: .public) \
      reused=\(transaction.isReusedConnection, privacy: .public) \
      dnsMs=\(ms(transaction.domainLookupStartDate, transaction.domainLookupEndDate), privacy: .public) \
      connectMs=\(ms(transaction.connectStartDate, transaction.connectEndDate), privacy: .public) \
      tlsMs=\(ms(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate), privacy: .public) \
      ttfbMs=\(ms(transaction.requestStartDate, transaction.responseStartDate), privacy: .public) \
      totalMs=\(ms(transaction.fetchStartDate, transaction.responseEndDate), privacy: .public)
      """
    )
  }
}

extension Duration {
  /// This duration in milliseconds as a Double (for latency logging). Expressed
  /// as a ratio of two `Duration`s rather than reassembled from `components`,
  /// which meant restating the attoseconds-per-millisecond constant by hand.
  fileprivate var milliseconds: Double {
    self / Duration.milliseconds(1)
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
