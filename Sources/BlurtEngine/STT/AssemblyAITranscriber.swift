import AssemblyAI
import Foundation
import os

/// `TranscriberProtocol` backed by AssemblyAI's **dictation** API.
///
/// A single `POST dictation.assemblyai.com/v1/transcribe/live` carries a JSON
/// `config` part plus the captured audio (raw S16LE PCM, exactly the bytes the
/// mic recorded — there is no re-encoding pass), and the response body carries
/// both the verbatim transcript and an LLM-rewritten version with disfluencies
/// removed, produced by applying `CleanupInstruction.text` server-side.
///
/// **Every request asks for that rewrite** — `llm_instruction` rides the config
/// unconditionally, and the config carries no on/off switch at all. Which of the
/// two transcripts gets pasted is decided on the *response*, by the "enhanced
/// transcripts" setting (on by default): see `transcript(from:enhanced:)`, which also
/// states what that costs a user who has it off.
/// No upload step, no job submission, no polling — one
/// request per utterance covers transcription *and* cleanup. `config` leads the
/// body because the streaming route cannot open its upstream call without it —
/// see `transcribePath` and `streamedBody`. The service picks
/// the STT model server-side. The streaming route accepts **at most 120 s** of
/// audio; a longer recording (Blurt records up to 20 minutes) is refused with
/// `413 audio_too_large` and sent again, whole, to `/v1/transcribe` — the one
/// second request there is, see `AssemblyAITranscriber+LiveCapFallback.swift`.
/// There is no documented *minimum* — the ~80 ms floor is this
/// client's own, see `SyncSTTLimits.minPCMBytes`. The rewrite is best-effort
/// with a 5 s server-side deadline, so a failure still returns the verbatim
/// transcript (`llm_response` null, `llm_error` set).
///
/// **Every request this file makes is one the reference describes** — path,
/// header, part order, config keys, response keys, error keys. That is a
/// standing rule, not an accident of the current shape: measured-but-
/// undocumented behaviour is not something to build on, however well it works.
/// `llm: null` is the one that was removed for it (see
/// `DictationConfig.llmInstruction`). The single header the reference does not
/// mention is `User-Agent`, which every HTTP client sends regardless — see
/// `UserAgent` for why naming Blurt and its version there is not an exception
/// to the rule above but a request the rule never governed.
public struct AssemblyAITranscriber: TranscriberProtocol {
  /// Latency instrumentation for the dictation round-trip. Findable via:
  ///   log show --predicate 'subsystem == "dev.alex.blurt" && category == "Transcriber"' --last 1h
  ///
  /// Type-scoped like every other logger in the engine (`MicCapture`,
  /// `DictationLog`, `AudioRouteMonitor`) rather than a module-global, and
  /// internal so `DictationUploadDelegate` in `DictationUploadMetrics.swift`
  /// writes the same category — one category, two files.
  static let log = HostIdentity.current.logger("Transcriber")
  public static let defaultBaseURL = URL(staticString: "https://dictation.assemblyai.com")
  private let apiKeyProvider: @Sendable () -> String?
  /// Read per request, so the host can change while the app runs. Internal for `warmUp()`.
  var baseURL: URL { baseURLProvider() }
  private let baseURLProvider: @Sendable () -> URL
  let transport: any HTTPTransport
  private let enhancedTranscriptsEnabled: @Sendable () -> Bool
  private let rewriteMode: @Sendable () -> RewriteMode
  /// The most audio the over-cap fallback's copy may hold before it is dropped
  /// and the fallback fails cleanly instead. Internal and settable so tests can
  /// trip the guard with a few bytes; production never changes it.
  var bufferedAudioByteCap = SyncSTTLimits.maxBufferedAudioBytes

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
  /// overlaps the recording. Every dictation starts here. There is exactly one
  /// way onto the buffered route (`bufferedTranscribePath`): this route refusing
  /// a recording past its documented 120 s cap with `413 audio_too_large`. It is
  /// not a latency fallback — nothing else, no timeout, no other error, takes
  /// the slower path — and it is logged when it happens, so the latency of
  /// every dictation under two minutes is still this route's alone.
  private static let transcribePath = "v1/transcribe/live"

  /// `enhancedTranscripts` decides, per response, which of the two transcripts
  /// the route returns gets pasted — it no longer shapes the request, which
  /// always asks for the rewrite; `rewriteMode` picks the rewrite's model
  /// (`RewriteModeStore`). The style appended to the cleanup instruction is the
  /// press's, carried on the context (`TranscriptionContext.styleInstructions`)
  /// — one profile's text, never a join of several (see `StyleProfileStore`).
  /// Both settings are
  /// read at every `transcribe` so a settings change applies to the next
  /// dictation without rebuilding the transcriber. `nil` (the default) reads
  /// the corresponding store — spelled as optionals rather than default
  /// closures because a public default argument can't reference a store's
  /// internal member.
  public init(
    apiKeyProvider: @escaping @Sendable () -> String? = { APIKeyStore.current },
    baseURL: @escaping @Sendable () -> URL = { AssemblyAITranscriber.defaultBaseURL },
    transport: any HTTPTransport = URLSession.shared,
    enhancedTranscripts: (@Sendable () -> Bool)? = nil,
    rewriteMode: (@Sendable () -> RewriteMode)? = nil
  ) {
    self.apiKeyProvider = apiKeyProvider
    self.baseURLProvider = baseURL
    self.transport = transport
    self.enhancedTranscriptsEnabled = enhancedTranscripts ?? { EnhancedTranscriptsStore().isEnabled }
    self.rewriteMode = rewriteMode ?? { RewriteModeStore().mode }
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
    // Read once, so a mid-recording flip can't split the request from the paste.
    let enhanced = enhancedTranscriptsEnabled()
    let config = try makeConfigData(
      sampleRate: sampleRate,
      sttPrompt: STTPrompt.text(context: context),
      keytermsPrompt: KeyTerms.fitted(context?.keyTerms ?? []),
      customStyle: context?.styleInstructions,
      enhanced: enhanced)
    let request = makeRequest(path: Self.transcribePath, apiKey: apiKey, boundary: boundary)

    // The capture feed goes through `relay` on its way to the upload, which keeps
    // a copy of every audio byte for the over-cap fallback and — the part that
    // matters — keeps reading the feed after the streaming request has failed,
    // so a recording refused mid-speech is still captured to key-up. A child
    // task, so cancelling this dictation cancels it, and every exit below that
    // doesn't await it (success, and every other error) cancels it on the way
    // out, which ends the feed exactly as the cancelled body producer used to.
    let (liveFrames, liveFeed) = AsyncStream.makeStream(of: Data.self)
    async let recording = Self.relay(frames, to: liveFeed, keepingAtMost: bufferedAudioByteCap)
    let progress = UploadProgress()
    let body = streamedBody(
      frames: liveFrames, config: config, boundary: boundary, progress: progress)
    let data: Data
    do {
      data = try await send(
        request, streaming: body, sampleRate: sampleRate, progress: progress)
    } catch is LiveCapExceeded {
      // The one trigger. Everything else propagates exactly as before.
      Self.log.notice(
        """
        live route refused the recording past its cap (413 audio_too_large) after \
        \(SyncSTTLimits.durationMs(ofPCMBytes: progress.audioBytes, rate: sampleRate), privacy: .public) ms; \
        recording on for the buffered route
        """)
      data = try await sendBuffered(
        await recording, config: config, apiKey: apiKey, boundary: boundary, sampleRate: sampleRate)
    }
    guard let response = try? JSONDecoder().decode(DictationResponse.self, from: data) else {
      throw AssemblyAIError.malformedResponse
    }
    Self.logServerMetrics(response)
    return transcript(from: response, enhanced: enhanced)
  }

  /// Which of the two transcripts in the response to paste.
  ///
  /// **This is the enhanced-transcripts switch.** The config always asks for the
  /// rewrite, so both transcripts are in hand by the time this runs and the
  /// setting is a pure choice between them: off means paste `text` exactly as
  /// spoken, on means prefer the rewrite. Read fresh per request, so a toggle
  /// applies to the next dictation without rebuilding the transcriber.
  ///
  /// It used to be a *request* switch — an explicit null `llm`, the only off
  /// state the route has, since omitting the instruction merely selects the
  /// service's own default cleanup. Deciding here instead costs a rewrite the
  /// user never sees: with the setting off they still wait out its ~5 s
  /// server-side budget and are still billed for it. What it buys is one request
  /// shape to reason about, and a switch that cannot disagree with the response
  /// it was applied to.
  ///
  /// With the setting on, the rewrite is best-effort, so anything unusable
  /// degrades to the verbatim transcript rather than an error. Blank counts as
  /// unusable alongside null: the service nulls out an empty rewrite, but a ""
  /// slipping through would strand the utterance — the pipeline drops a
  /// whitespace-only transcript to `.idle` without pasting or reporting, wasting
  /// the good verbatim `text` beside it.
  private func transcript(from response: DictationResponse, enhanced: Bool) -> String {
    guard enhanced else { return response.text }
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
  /// impossible by construction, and nothing does now. `frames` here is
  /// `relay`'s output, not the capture feed itself: tearing this producer down
  /// ends the *streaming request's* view of the audio, while the capture keeps
  /// flowing into the fallback's copy for as long as `transcribe` waits on it.
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

  /// Builds the JSON `config` part sent alongside the audio. Both steering
  /// fields are included only when non-empty: an empty `sttPrompt`
  /// omits `stt_prompt` (no prior text, so the model works from the audio alone
  /// and the service's managed default prompt applies) and an empty
  /// `keytermsPrompt` omits `keyterms_prompt` (which would otherwise ask to boost
  /// nothing). `prompt` is `stt_prompt`'s other name and must never ride
  /// alongside it — see `STTPrompt`. The cleanup instruction is
  /// `cleanupInstruction()`'s and rides every request, whatever the
  /// enhanced-transcripts setting says — that switch is applied to the response,
  /// in `transcript(from:enhanced:)`. Internal so tests can assert the
  /// config wiring without inspecting the multipart upload body (which
  /// `URLProtocol` mocks can't observe reliably for `upload(from:)`).
  /// Neither steering field is defaulted: every caller states both, so what a
  /// given request does and does not steer with is readable at the call site
  /// rather than inferred from which argument was left off.
  /// `enhanced` is the request's reading of the setting; nil reads it now.
  func makeConfigData(
    sampleRate: Int, sttPrompt: String, keytermsPrompt: [String], customStyle: String?,
    enhanced: Bool? = nil
  ) throws -> Data {
    try JSONEncoder().encode(
      DictationConfig(
        sampleRate: sampleRate,
        channels: 1,
        sttPrompt: sttPrompt,
        keytermsPrompt: keytermsPrompt,
        llmInstruction: cleanupInstruction(appending: customStyle),
        // Only while the rewrite is pasted: off, a slower model only adds latency.
        rewriteMode: (enhanced ?? enhancedTranscriptsEnabled()) ? rewriteMode().wireValue : nil
      )
    )
  }

  /// The cleanup instruction this request asks the route to rewrite with, or nil
  /// to leave the wording to the service — which is *not* the same as no
  /// rewrite; see `DictationConfig.llmInstruction`.
  ///
  /// `customStyle` is the press's style (`TranscriptionContext.styleInstructions`).
  private func cleanupInstruction(appending customStyle: String?) -> String? {
    guard let instruction = CleanupInstruction.sendable(appending: customStyle) else {
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
      return nil
    }
    return instruction
  }

  // MARK: - Networking helpers

  /// The headers both dictation requests carry — the streaming one and the
  /// buffered fallback — stated once, so the second request cannot drift from
  /// the first in anything but its path and body.
  func makeRequest(path: String, apiKey: String, boundary: String) -> URLRequest {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "POST"
    // Bounds a stalled connection; see `requestTimeoutSeconds` for why an idle
    // timeout is the right shape here — and note that on the streaming request it
    // covers the recording as well as the round trip, which is exactly what an
    // idle timeout does and a total one would not.
    request.timeoutInterval = Self.requestTimeoutSeconds
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    // Names the client and its release to the service (`Blurt/<version>`) in place
    // of `URLSession`'s default agent, which reports the opaque build counter.
    // The one header here the reference does not describe, and the exception is
    // principled rather than a crack in that rule — see `UserAgent`.
    request.setUserAgent()
    return request
  }

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
    if Self.isLiveCapRefusal(response, body: data) { throw LiveCapExceeded() }
    try Self.requireSuccess(response, body: data)
    return data
  }

  // The request/response types this encodes and decodes — `DictationConfig`,
  // `DictationResponse`, `ErrorResponse` — live in `DictationWireTypes.swift`,
  // and the upload's instrumentation — `UploadProgress`,
  // `DictationUploadDelegate` — in `DictationUploadMetrics.swift`. Both split
  // out to stay within the lint file-length budget. They are the JSON contract
  // and the measurement; everything here is the transport.
}

// `AssemblyAIError`, the errors this transport raises — and `requireSuccess`/`errorMessage`, which turn a
// failed response into one — live in `AssemblyAIError.swift`, and
// the over-cap fallback to `/v1/transcribe` — its recording copy and its request — in
// `AssemblyAITranscriber+LiveCapFallback.swift`. Both split out for the lint file-length budget.
