import Foundation
import os

/// Latency instrumentation for the dictation round-trip. Findable via:
///   log show --predicate 'subsystem == "dev.alex.blurt" && category == "Transcriber"' --last 1h
/// `TranscriberProtocol` backed by AssemblyAI's **dictation** API.
///
/// A single `POST dictation.assemblyai.com/v1/transcribe/live` carries a JSON
/// `config` part plus the captured audio (raw S16LE PCM, exactly the bytes the
/// mic recorded — there is no re-encoding pass), and the response body carries
/// both the verbatim transcript and — when the config requests one via
/// `llm_instruction` (the "enhanced transcripts" setting, on by default) — an
/// LLM-rewritten version with disfluencies removed, produced by applying
/// `CleanupInstruction.text` server-side. Turning that setting off takes an
/// explicit null `llm`, not a missing instruction; `Rewrite` has the measured
/// reason why.
/// No upload step, no job submission, no polling — one
/// request per utterance covers transcription *and* cleanup. `config` leads the
/// body because the streaming route cannot open its upstream call without it —
/// see `transcribePath` and `streamedBody`. The service picks
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

  /// The dictation API's **streaming** route, relative to `baseURL`.
  ///
  /// More than a respelling of the unversioned `/transcribe` it replaced: that
  /// route parsed the body only once complete, so inference could not begin
  /// until the last byte landed (and it required the opposite part order). This
  /// one opens its upstream STT call as soon as `config` arrives, so inference
  /// overlaps the recording. No fallback to the old route — a client that can
  /// silently take the slower path is one whose latency nobody can reason about.
  private static let transcribePath = "v1/transcribe/live"

  /// `enhancedTranscripts` decides, per request, whether the config asks for the
  /// cleanup rewrite at all; `customStyle` supplies the *active* style
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
    frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?
  ) async throws -> String {
    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
      throw BlurtError.apiKeyMissing
    }
    let boundary = "blurt-\(UUID().uuidString)"
    // Encoded before the request opens, not from inside the body producer: the
    // `config` part leads the wire now, so an unencodable config has to fail
    // here — mid-body it would abort a request whose upstream call was open.
    //
    // What goes on the wire is the prior text (recent dictations, then the
    // text before the cursor) and the key terms as keyterms prompting. App name,
    // window title, field label and selected text stay on the machine —
    // `STTPrompt` draws that line, so nothing is filtered here.
    let config = try makeConfigData(
      sampleRate: sampleRate,
      sttPrompt: STTPrompt.text(context: context),
      keytermsPrompt: KeytermsBoost.fitted(context?.keyTerms ?? []))

    var request = URLRequest(url: baseURL.appending(path: Self.transcribePath))
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
      frames: frames, config: config, boundary: boundary, progress: progress)
    let data = try await send(
      request, streaming: body, sampleRate: sampleRate, progress: progress)
    guard let response = try? JSONDecoder().decode(DictationResponse.self, from: data) else {
      throw AssemblyAIError.malformedResponse
    }
    // The rewrite is best-effort, so anything unusable degrades to the verbatim
    // transcript rather than an error — and a null `llm_response` is also what a
    // declined rewrite looks like (`Rewrite.disabled`), which is the same
    // fallback by a different route. Blank counts as unusable alongside null:
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

  /// The multipart body, in the order the streaming route requires: the whole
  /// `config` part, then the `audio` part's headers, then each captured frame as
  /// it arrives, then the closing boundary once the frames stop.
  ///
  /// `config` goes **first**: the route's contract, not a preference — an
  /// audio-first body earns `400 the config part must be sent before the audio
  /// part on the streaming endpoint, because the upstream call cannot be opened
  /// without it` (verified against the service, 2026-09-09). Leading with it is
  /// also what buys the latency, since the service opens its upstream STT call
  /// the moment it lands. The config is therefore settled before any audio moves
  /// — see `transcribe`, and `DictationSession.startUpload` for where the
  /// press-time Accessibility read is awaited so `stt_prompt` still
  /// carries the text before the cursor.
  ///
  /// Finishing the stream closes the body, so `frames` ending is end-of-audio —
  /// and nothing happens between the last frame and that close now, the other
  /// half of the win: the old body waited for the context read here first.
  ///
  /// Abandonment is `onTermination` cancelling this producer, and there is no
  /// in-band check: the producer is an unstructured `Task` and does not inherit
  /// the upload task's cancellation, so by the time it could notice, the
  /// continuation is torn down and its yields are already no-ops. The teardown
  /// is the mechanism; the config-last body used to make a complete body
  /// impossible by construction, and nothing does now.
  ///
  /// The stream buffers without bound, which is deliberate: frames can only
  /// arrive as fast as the microphone produces them, so a backlog forms only
  /// when the uplink is slower than realtime — and then the audio has to wait
  /// somewhere regardless. The recording cap bounds it to
  /// `SyncSTTLimits.maxAudioSeconds` of PCM.
  private func streamedBody(
    frames: AsyncStream<Data>, config: Data, boundary: String, progress: UploadProgress
  ) -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let producer = Task {
        continuation.yield(DictationMultipart.configHead(config: config, boundary: boundary))
        continuation.yield(DictationMultipart.audioPartHeader(boundary: boundary))
        for await frame in frames {
          progress.recordFrame(bytes: frame.count)
          continuation.yield(frame)
        }
        // The too-short-clip floor, enforced here and not only by
        // `DictationSession.performRelease`: this producer has nothing left to
        // wait for, so it could close the request the moment `frames` ends and
        // beat that guard on a fast link — the race the guard used to win by
        // construction, when the config part waited on the pipeline's context.
        // What it costs to lose is not an error but a pointless billed request:
        // the route answers a 20 ms clip with 200 and an empty transcript
        // (measured), which the pipeline then drops to `.idle` anyway.
        guard progress.audioBytes >= SyncSTTLimits.minPCMBytes else {
          continuation.finish(throwing: AssemblyAIError.audioTooShort)
          return
        }
        continuation.yield(DictationMultipart.closingBoundary(boundary: boundary))
        continuation.finish()
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
  /// fields are included only when non-empty: an empty `sttPrompt`
  /// omits `stt_prompt` (no prior text, so the model works from the audio alone
  /// and the service's managed default prompt applies) and an empty
  /// `keytermsPrompt` omits `keyterms_prompt` (which would otherwise ask to boost
  /// nothing). `prompt` is `stt_prompt`'s other name and must never ride
  /// alongside it — see `STTPrompt`. The rewrite request is `rewriteRequest()`'s, which reads
  /// the enhanced-transcripts setting per call. Internal so tests can assert the
  /// config wiring without inspecting the multipart upload body (which
  /// `URLProtocol` mocks can't observe reliably for `upload(from:)`).
  /// Neither steering field is defaulted: every caller states both, so what a
  /// given request does and does not steer with is readable at the call site
  /// rather than inferred from which argument was left off.
  func makeConfigData(
    sampleRate: Int, sttPrompt: String, keytermsPrompt: [String]
  ) throws -> Data {
    try JSONEncoder().encode(
      DictationConfig(
        sampleRate: sampleRate,
        channels: 1,
        sttPrompt: sttPrompt,
        keytermsPrompt: keytermsPrompt,
        rewrite: rewriteRequest()
      )
    )
  }

  /// Which of the route's three rewrite states this request asks for — see
  /// `Rewrite` for the wire mapping and why "no instruction" is not "no
  /// rewrite".
  ///
  /// Read fresh per request, so toggling **enhanced transcripts** or switching
  /// style profiles applies to the next dictation without rebuilding the
  /// transcriber.
  private func rewriteRequest() -> Rewrite {
    guard enhancedTranscriptsEnabled() else { return .disabled }
    guard let instruction = CleanupInstruction.sendable(appending: customStyle()) else {
      // Unreachable while the tests run: `CleanupInstructionTests` asserts the length.
      // Logged rather than trusted because the failure it guards against is silent —
      // the user would get the service's default cleanup instead of their style
      // profile's, with a 200 and a plausible transcript to hide it.
      Self.log.error(
        """
        cleanup instruction is \(CleanupInstruction.text.utf8.count, privacy: .public) UTF-8 bytes, \
        over the \(CleanupInstruction.characterCap, privacy: .public) cap; \
        falling back to the service default
        """)
      return .serviceDefault
    }
    return .instructed(instruction)
  }

  // MARK: - Networking helpers

  private func send(
    _ request: URLRequest, streaming body: AsyncThrowingStream<Data, any Error>,
    sampleRate: Int, progress: UploadProgress
  ) async throws -> Data {
    // Per-task delegate (not a session delegate) so this rides along on whatever
    // transport was injected — `URLSession.shared` in production, a fake in
    // tests — without reconfiguring it. `DictationUploadDelegate` logs the connect-vs-
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
  // `Rewrite`, `DictationResponse`, `ErrorResponse` — live in
  // `DictationWireTypes.swift`, and the upload's instrumentation —
  // `UploadProgress`, `DictationUploadDelegate` — in `DictationUploadMetrics.swift`. Both
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
  /// The recording ended below `SyncSTTLimits.minPCMBytes`, so the body was
  /// never closed — a belt on top of `DictationSession.performRelease`'s own
  /// guard rather than the only thing between a stray tap and a request billed
  /// for transcribing nothing. `awaitUpload` maps it to the same quiet `.idle`
  /// that guard produces, so whichever layer notices first the user sees the
  /// same nothing; the description below is a backstop, not a message anyone is
  /// expected to read.
  case audioTooShort

  var errorDescription: String? {
    switch self {
    case .http(let status, let message):
      if let message { return "AssemblyAI error \(status): \(message)" }
      return "AssemblyAI error \(status)"
    case .malformedResponse:
      return "Unexpected response from AssemblyAI."
    case .audioTooShort:
      return "That recording was too short to transcribe."
    }
  }
}
