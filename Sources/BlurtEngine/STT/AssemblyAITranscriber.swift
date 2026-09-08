import Foundation
import os

/// Latency instrumentation for the dictation round-trip. Findable via:
///   log show --predicate 'subsystem == "dev.alex.blurt" && category == "Transcriber"' --last 1h
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
  /// Latency instrumentation for the dictation round-trip. Findable via:
  ///   log show --predicate 'subsystem == "dev.alex.blurt" && category == "Transcriber"' --last 1h
  ///
  /// Type-scoped like every other logger in the engine (`MicCapture`,
  /// `DictationLog`, `AudioRouteMonitor`) rather than a module-global, and
  /// internal so `DictationUploadDelegate` in `DictationUploadMetrics.swift`
  /// writes the same category — one category, two files.
  static let log = HostIdentity.current.logger("Transcriber")
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
  /// the `llm` cleanup-rewrite block; `customStyle` supplies the *active* style
  /// profile's instructions, appended to that block's cleanup instruction — one
  /// profile's text, never a join of several (see `StyleProfileStore`). Both are
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
    self.customStyle = customStyle ?? { StyleProfileStore().activeInstructions }
  }

  // MARK: - Dictation request

  public func transcribe(
    frames: AsyncStream<Data>, sampleRate: Int, context: AsyncStream<TranscriptionContext?>
  ) async throws -> String {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      throw BlurtError.apiKeyMissing
    }
    let boundary = "blurt-\(UUID().uuidString)"

    var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
    request.httpMethod = "POST"
    // Bounds a stalled connection; see `requestTimeoutSeconds` for why an idle
    // timeout is the right shape here — and note it now has to cover the
    // recording as well as the round trip, which is exactly what an idle
    // timeout does and a total one would not.
    request.timeoutInterval = Self.requestTimeoutSeconds
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let progress = UploadProgress()
    let body = streamedBody(
      frames: frames, sampleRate: sampleRate, boundary: boundary,
      context: context, progress: progress)
    let data = try await send(
      request, streaming: body, sampleRate: sampleRate, progress: progress)
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
      Self.log.warning(
        "llm rewrite unavailable (\(error, privacy: .public)); using verbatim transcript")
    }
    return response.text
  }

  /// The multipart body, produced in the only order a live recording allows:
  /// the `audio` part's headers, then each captured frame as it arrives, then
  /// the `config` part once the frames stop.
  ///
  /// `config` goes **last**. The dictation API permits it because it parses the
  /// body only once complete (verified against the service — sync's own
  /// streaming route requires the opposite order and would reject this). That
  /// ordering is load-bearing rather than incidental: it lets the press-time
  /// Accessibility context read resolve at *release*, exactly as it did when
  /// the whole request was built after recording. The producer therefore waits
  /// here, after the last frame, for the value the session pushes on `context` —
  /// the config carries the same `conversation_context` and `word_boost` it
  /// always did, decided at the same moment as before.
  ///
  /// Finishing the stream is what closes the multipart body and tells the
  /// service the utterance is over, so `frames` ending is end-of-audio.
  ///
  /// The stream buffers without bound, which is deliberate: frames can only
  /// arrive as fast as the microphone produces them, so a backlog forms only
  /// when the uplink is slower than realtime — and then the audio has to wait
  /// somewhere regardless. The recording cap bounds it to
  /// `SyncSTTLimits.maxAudioSeconds` of PCM.
  private func streamedBody(
    frames: AsyncStream<Data>, sampleRate: Int, boundary: String,
    context: AsyncStream<TranscriptionContext?>, progress: UploadProgress
  ) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let producer = Task {
        continuation.yield(Self.audioPartHeader(boundary: boundary))
        for await frame in frames {
          progress.recordFrame(bytes: frame.count)
          continuation.yield(frame)
        }
        do {
          // Wait for the session's press-time read, which it resolves at release
          // and sends here. A channel that finishes without a value means the
          // dictation was abandoned, and the cancellation check below is what
          // stops a config part going out for it.
          var resolved: TranscriptionContext?
          for await value in context {
            resolved = value
            break
          }
          try Task.checkCancellation()
          // The prior dialogue that goes on the wire: the user's recent
          // dictations, then the text before the cursor (empty when there is
          // neither, which omits the field). App name, window title, field
          // label and selected text stay on the machine — `ConversationContext`
          // draws that line, so nothing is filtered here.
          let config = try makeConfigData(
            sampleRate: sampleRate,
            conversationContext: ConversationContext.turns(context: resolved),
            // The other steering field: the user's key terms as a word-boost
            // list, fitted to its own (different) cap.
            wordBoost: KeytermsBoost.fitted(resolved?.keyTerms ?? []))
          continuation.yield(Self.configTail(config: config, boundary: boundary))
          continuation.finish()
        } catch {
          // A truncated body would earn a generic 400 from the service; finish
          // with the real error so the failure names its own cause.
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in producer.cancel() }
    }
  }

  /// Pre-open and pool a connection to the dictation host so the request opened
  /// at press starts streaming immediately instead of spending its first
  /// ~170 ms on DNS+TCP+TLS (more on mobile — measured).
  ///
  /// The reason changed with the chunked upload and is worth stating, because
  /// the obvious reading is now wrong. It used to keep connection setup off the
  /// *release* hot path, where the user was waiting. The request now opens at
  /// press, so its handshake overlaps the recording either way and no longer
  /// sits on the wait at all. What the warm-up still buys is the audio starting
  /// to move ~170 ms sooner — which is free on a fast uplink and worth having on
  /// a saturated one, where a late start is a backlog that never clears and adds
  /// its own delay to the post-speech wait.
  ///
  /// Measured rather than assumed (2026-09-08), because "the POST opens at press
  /// now, so this races it" is the plausible objection: with a fresh
  /// `URLSession`, the POST reports `isReusedConnection == true` both after a
  /// 250 ms mic bring-up and when fired back-to-back with the warm-up. URLSession
  /// coalesces onto the in-flight connection, so this costs one throwaway GET
  /// and never a second handshake.
  ///
  /// A throwaway GET to the host
  public func warmUp() async {
    var request = URLRequest(url: baseURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 5
    let clock = ContinuousClock()
    let start = clock.now
    _ = try? await transport.data(for: request)
    let elapsedMs = (clock.now - start).milliseconds
    Self.log.info(
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
      Self.log.error(
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

  /// The `audio` part's framing — everything before the PCM bytes themselves,
  /// written once when the request opens so the frames that follow are just
  /// audio.
  ///
  /// Internal, not private, so tests can assert the wire format against the
  /// bytes. `FakeHTTPTransport` can observe the streamed body directly now
  /// (it collects the `AsyncThrowingStream`), but these two halves are still
  /// where the framing — boundaries, part headers, the `audio.pcm` filename,
  /// CRLF placement — is stated once.
  static func audioPartHeader(boundary: String) -> Data {
    framed(
      "--\(boundary)\r\n",
      "Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n",
      "Content-Type: audio/pcm\r\n\r\n")
  }

  /// UTF-8 encodes the multipart framing. One definition for both halves of the
  /// body — the CRLF placement and part headers are what the file's comments
  /// call the contract, so they are stated once rather than once per half.
  private static func framed(_ parts: String...) -> Data {
    Data(parts.joined().utf8)
  }

  /// Everything after the last audio frame: the `audio` part's terminating
  /// CRLF, the whole `config` part, and the closing boundary. Written when the
  /// recording ends — see `streamedBody` for why `config` is last.
  static func configTail(config: Data, boundary: String) -> Data {
    var tail = framed(
      "\r\n",
      "--\(boundary)\r\n",
      "Content-Disposition: form-data; name=\"config\"\r\n",
      "Content-Type: application/json\r\n\r\n")
    tail.append(config)
    tail.append(framed("\r\n", "--\(boundary)--\r\n"))
    return tail
  }

  // MARK: - Networking helpers

  private func send(
    _ request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    sampleRate: Int, progress: UploadProgress
  ) async throws -> Data {
    // Per-task delegate (not a session delegate) so this rides along on whatever
    // transport was injected — `URLSession.shared` in production, a fake in
    // tests — without reconfiguring it. `MetricsLogger` logs the connect-vs-
    // inference split and refuses a body replay; the lines below are the
    // always-available totals.
    // Not optional instrumentation: this delegate also refuses `URLSession`'s
    // request to replay the body, which is what stands between an internal retry
    // and a blank transcript. Dropping it would drop that guarantee silently.
    let metrics = DictationUploadDelegate()
    let clock = ContinuousClock()
    let start = clock.now
    let (data, response) = try await transport.upload(
      for: request, streaming: body, delegate: metrics)
    let finished = clock.now
    let audioMs = SyncSTTLimits.durationMs(ofPCMBytes: progress.audioBytes, rate: sampleRate)
    // `wallMs` now spans the recording too, because the request opens at press
    // — so on its own it says nothing about how long the user waited.
    // `postSpeechMs` is that number: last audio frame handed to the upload
    // until the transcript landed. It is the one to compare against the old
    // buffered round trip, and against the service's own `post_speech_ms`.
    let wallMs = (finished - start).milliseconds
    let postSpeechMs = progress.lastFrameAt.map { (finished - $0).milliseconds }
    Self.log.info(
      """
      dictation round-trip audioMs=\(audioMs, privacy: .public) \
      postSpeechMs=\(postSpeechMs ?? -1, format: .fixed(precision: 0), privacy: .public) \
      wallMs=\(wallMs, format: .fixed(precision: 0), privacy: .public)
      """)
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
  // `DictationWireTypes.swift`, and the upload's instrumentation —
  // `UploadProgress`, `MetricsLogger` — in `DictationUploadMetrics.swift`. Both
  // split out to stay within the lint file-length budget. They are the JSON
  // contract and the measurement; everything here is the transport.
}

// `Duration.milliseconds` — the latency-logging conversion this file's request
// timing uses — moved to `Duration+Milliseconds.swift` when `MicCapture` needed
// the same thing for its liveness-gap line. It was `fileprivate` here; a second
// copy is an "invalid redeclaration", not a shadow.

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
