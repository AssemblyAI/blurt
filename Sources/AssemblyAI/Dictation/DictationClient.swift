public import Foundation
public import os

/// AssemblyAI's **dictation** API: one utterance in, one final transcript out.
///
/// A single `POST dictation.assemblyai.com/v1/transcribe/live` carries a JSON
/// `config` part plus the captured audio (raw S16LE PCM, uploaded as it is
/// recorded), and the response carries both the verbatim transcript and, when
/// the config asked for one, the server-side LLM rewrite. No upload step, no job
/// submission, no polling. `config` leads the body because the streaming route
/// cannot open its upstream call without it — see `transcribePath` and
/// `streamedBody`. The service picks the STT model server-side.
///
/// The streaming route accepts **at most 120 s** of audio; a longer recording is
/// refused with `413 audio_too_large` and sent again, whole, to `/v1/transcribe`
/// — the one second request there is, see `DictationClient+LiveCapFallback.swift`.
///
/// **Every request this type makes is one the reference describes** — path,
/// header, part order, config keys, response keys, error keys. That is a
/// standing rule: measured-but-undocumented behaviour is not something to build
/// on, however well it works. The single header the reference does not mention
/// is `User-Agent`, which every HTTP client sends regardless; the caller names
/// its own (`userAgent`).
///
/// What it deliberately doesn't decide: which prompt, cleanup instruction or key
/// terms ride the config, or which of the response's two transcripts to use.
/// Those are the calling app's, and arrive as the `DictationConfig` it builds
/// and leave as the `DictationResponse` it reads.
public struct DictationClient: Sendable {
  /// The dictation API's default host, used unless the caller names another.
  public static let defaultBaseURL = URL(literal: "https://dictation.assemblyai.com")

  /// The most audio the over-cap fallback's copy may hold: the buffered
  /// route's documented 256 MB part limit, read as 10⁶-byte megabytes — the
  /// conservative reading of an unstated unit. A guard, not a working limit: a
  /// 20-minute recording is ~38 MB of 16 kHz mono PCM. Past it the copy is
  /// dropped at once and the fallback fails cleanly with
  /// `AssemblyAIError.recordingTooLarge` rather than sending a truncated
  /// recording.
  static let maxBufferedAudioBytes = 256_000_000

  /// Idle timeout for the transcribe round trip — `URLRequest.timeoutInterval` is
  /// reset each time data moves, so this bounds *stalls*, not total elapsed time.
  /// 90 s is the client timeout the dictation API documents: generous over the
  /// STT upstream's ~30 s inference deadline plus the rewrite's 5 s budget, so
  /// the server — not the client — decides when a slow request has failed,
  /// while a connection that stops delivering bytes still can't hang forever.
  static let requestTimeoutSeconds: TimeInterval = 90

  /// The dictation API's **streaming** route, relative to `baseURL`.
  ///
  /// It opens its upstream STT call as soon as `config` arrives, so inference
  /// overlaps the recording. Every dictation starts here. There is exactly one
  /// way onto the buffered route (`bufferedTranscribePath`): this route refusing
  /// a recording past its documented 120 s cap with `413 audio_too_large`. It is
  /// not a latency fallback — nothing else, no timeout, no other error, takes
  /// the slower path — and it is logged when it happens.
  static let transcribePath = "v1/transcribe/live"

  /// Read per request, so the host can change while the app runs.
  var baseURL: URL { baseURLProvider() }
  private let baseURLProvider: @Sendable () -> URL
  let transport: any HTTPTransport
  let userAgent: String?
  /// Where the round trip's latency lines go. The caller may pass its own so
  /// they land beside its other logs.
  let log: Logger
  /// The fewest audio bytes worth sending: below it the body is never closed and
  /// the request fails with `AssemblyAIError.audioTooShort`, rather than paying
  /// for a request the route answers with an empty transcript. The reference
  /// documents no minimum, so this is the caller's (0, the default, sends any
  /// recording).
  let minimumAudioBytes: Int
  /// The most audio the over-cap fallback's copy may hold before it is dropped.
  /// Internal and settable so tests can trip the guard with a few bytes.
  var bufferedAudioByteCap = Self.maxBufferedAudioBytes

  /// - Parameters:
  ///   - baseURL: read at every request, so a data-zone change applies to the next one.
  ///   - userAgent: identifies the calling app; nil sends URLSession's default.
  ///   - minimumAudioBytes: see the property.
  ///   - log: where the latency lines go; nil sends them to the SDK's own log.
  @preconcurrency
  public init(
    baseURL: @escaping @Sendable () -> URL = { Self.defaultBaseURL },
    transport: any HTTPTransport = URLSession.shared,
    userAgent: String? = nil,
    minimumAudioBytes: Int = 0,
    log: Logger? = nil
  ) {
    self.baseURLProvider = baseURL
    self.transport = transport
    self.userAgent = userAgent
    self.minimumAudioBytes = minimumAudioBytes
    self.log = log ?? SDKLog.dictation
  }

  /// Milliseconds of audio a raw S16LE mono byte count represents at `rate`, for
  /// the latency lines. Converts before dividing so a trailing partial sample
  /// can't truncate the result.
  static func durationMs(ofPCMBytes byteCount: Int, rate: Int) -> Int {
    guard rate > 0 else {
      return 0
    }
    return Int((Double(byteCount) / Double(FrameAligner.bytesPerFrame) / Double(rate)) * 1_000)
  }

  /// Transcribes an utterance that is **still being recorded**: the request opens
  /// now and `frames` (raw S16LE PCM at `config.sampleRate`) feeds it; finishing
  /// `frames` is end-of-audio. Returns the service's response once it lands.
  ///
  /// Cancelling the calling task abandons the request and every copy of the
  /// audio with it. A recording the streaming route refuses past its cap is
  /// recorded on to its end and sent to the buffered route, behind this same
  /// call; `frames` is read to its end either way.
  public func transcribe(
    frames: AsyncStream<Data>,
    config: DictationConfig,
    apiKey: String
  ) async throws -> DictationResponse {
    let boundary = "dictation-\(UUID().uuidString)"
    // Encoded before the request opens, not from inside the body producer: the
    // `config` part leads the wire, so an unencodable config has to fail here —
    // mid-body it would abort a request whose upstream call was open.
    let configData = try JSONEncoder().encode(config)
    let sampleRate = config.sampleRate
    let request = makeRequest(path: Self.transcribePath, apiKey: apiKey, boundary: boundary)

    // The capture feed goes through `relay` on its way to the upload, which keeps
    // a copy of every audio byte for the over-cap fallback and — the part that
    // matters — keeps reading the feed after the streaming request has failed,
    // so a recording refused mid-speech is still captured to its end. A child
    // task, so cancelling this call cancels it, and every exit below that
    // doesn't await it (success, and every other error) cancels it on the way
    // out, which ends the feed.
    let (liveFrames, liveFeed) = AsyncStream.makeStream(of: Data.self)
    async let recording = Self.relay(frames, to: liveFeed, keepingAtMost: bufferedAudioByteCap, log: log)
    let progress = UploadProgress()
    let data: Data
    do {
      // Scoped to the streaming request: nothing after it may keep the body alive.
      let body = streamedBody(
        frames: liveFrames,
        config: configData,
        boundary: boundary,
        progress: progress
      )
      data = try await send(
        request,
        streaming: body,
        sampleRate: sampleRate,
        progress: progress
      )
    } catch is LiveCapExceeded {
      // The streaming request is over, so end its view of the audio now. Left
      // open, `relay` would go on feeding the body's producer, which would
      // copy every frame for the rest of the recording into a body nobody
      // reads — a second unbounded copy beside the fallback's own.
      liveFeed.finish()
      // The one trigger. Everything else propagates exactly as before.
      log.notice(
        """
        live route refused the recording past its cap (413 audio_too_large) after \
        \(Self.durationMs(ofPCMBytes: progress.audioBytes, rate: sampleRate), privacy: .public) ms; \
        recording on for the buffered route
        """
      )
      data = try await sendBuffered(
        await recording,
        config: configData,
        apiKey: apiKey,
        boundary: boundary,
        sampleRate: sampleRate
      )
    }
    guard let response = try? JSONDecoder().decode(DictationResponse.self, from: data) else {
      throw AssemblyAIError.malformedResponse
    }
    logServerMetrics(response)
    return response
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
  /// the moment it lands.
  ///
  /// Abandonment is `onTermination` cancelling this producer, and there is no
  /// in-band check: the producer is an unstructured `Task` and does not inherit
  /// the upload task's cancellation, so by the time it could notice, the
  /// continuation is torn down and its yields are already no-ops. `frames` here
  /// is `relay`'s output, not the capture feed itself: tearing this producer
  /// down ends the *streaming request's* view of the audio, while the capture
  /// keeps flowing into the fallback's copy for as long as `transcribe` waits.
  ///
  /// The stream buffers without bound, which is deliberate: frames can only
  /// arrive as fast as the microphone produces them, so a backlog forms only
  /// when the uplink is slower than realtime — and then the audio has to wait
  /// somewhere regardless.
  private func streamedBody(
    frames: AsyncStream<Data>,
    config: Data,
    boundary: String,
    progress: UploadProgress
  ) -> AsyncThrowingStream<Data, any Error> {
    let audioFloor = minimumAudioBytes
    return AsyncThrowingStream { continuation in
      let producer = Task {
        continuation.yield(DictationMultipart.configHead(config: config, boundary: boundary))
        continuation.yield(DictationMultipart.audioPartHeader(boundary: boundary))
        // `frames` is `relay`'s output, already whole 16-bit samples (`FrameAligner`).
        for await frame in frames {
          progress.recordFrame(bytes: frame.count)
          continuation.yield(frame)
        }
        // The caller's too-short floor, enforced here as well as wherever the
        // caller decides not to send: this producer has nothing left to wait
        // for, so it could close the request the moment `frames` ends and beat
        // the caller's own check on a fast link. What it costs to lose is not an
        // error but a pointless billed request: the route answers a 20 ms clip
        // with 200 and an empty transcript (measured).
        guard progress.audioBytes >= audioFloor else {
          continuation.finish(throwing: AssemblyAIError.audioTooShort)
          return
        }
        continuation.yield(DictationMultipart.closingBoundary(boundary: boundary))
        continuation.finish()
      }
      continuation.onTermination = { _ in producer.cancel() }
    }
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
    request.authorize(apiKey: apiKey, userAgent: userAgent)
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    return request
  }

  private func send(
    _ request: URLRequest,
    streaming body: AsyncThrowingStream<Data, any Error>,
    sampleRate: Int,
    progress: UploadProgress
  ) async throws -> Data {
    // Per-task delegate (not a session delegate) so this rides along on whatever
    // transport was injected without reconfiguring it. Not optional
    // instrumentation: it also refuses `URLSession`'s request to replay the
    // body, which is what stands between an internal retry and a blank
    // transcript. Dropping it would drop that guarantee silently.
    let metrics = DictationUploadDelegate(log: log)
    let clock = ContinuousClock()
    let start = clock.now
    let (data, response) = try await transport.upload(
      for: request,
      streaming: body,
      delegate: metrics
    )
    let finished = clock.now
    let audioMs = Self.durationMs(ofPCMBytes: progress.audioBytes, rate: sampleRate)
    // `wallMs` spans the recording too, because the request opens with it — so
    // on its own it says nothing about how long the user waited.
    // `postSpeechMs` is that number: last audio frame handed to the upload
    // until the transcript landed, the one to compare against the service's
    // own `post_speech_ms`.
    let wallMs = (finished - start).dictationMilliseconds
    let postSpeechMs = progress.lastFrameAt.map { (finished - $0).dictationMilliseconds }
    log.info(
      """
      dictation round-trip audioMs=\(audioMs, privacy: .public) \
      postSpeechMs=\(postSpeechMs ?? -1, format: .fixed(precision: 0), privacy: .public) \
      wallMs=\(wallMs, format: .fixed(precision: 0), privacy: .public)
      """
    )
    if Self.isLiveCapRefusal(response, body: data) {
      throw LiveCapExceeded()
    }
    try Self.requireSuccess(response, body: data)
    return data
  }
}
