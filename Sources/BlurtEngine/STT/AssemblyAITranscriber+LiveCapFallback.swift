import AssemblyAI
import Foundation

// The over-cap fallback: what happens when the streaming route refuses a
// recording because it ran past that route's 120 s cap. Split from
// `AssemblyAITranscriber.swift` for the lint file-length budget, and because it
// is one decision with one trigger, readable in one place.
//
// **Why it exists.** Blurt records for up to 20 minutes
// (`SyncSTTLimits.maxAudioSeconds`), and the streaming route,
// `/v1/transcribe/live`, accepts at most 120 s: past that it answers
// `413 {"error_code": "audio_too_large"}`, mid-upload, as soon as the cap is
// passed. Without a fallback every dictation over two minutes failed at release
// with that 413 and lost everything the user said. The buffered route,
// `/v1/transcribe`, takes the same `config` and the same audio part, returns the
// same response, and accepts up to 20 minutes / 256 MB — documented at
// https://assemblyai.com/docs/api-reference/dictation-api/transcribe.md, which is
// what licenses calling it (AGENTS.md, "The reference is the source of truth").
//
// **What it costs.** A copy of the recording, held in memory for the length of
// the request — the thing the 2026-09-08 "`stop()` answers a byte count" rule
// removed from `MicCapture`. It comes back narrower than it left: it lives here,
// in the upload layer, never in the capture lock; it is built by `relay` on the
// upload's own task, off the capture delivery queue; it exists only to back this
// fallback, and it is dropped with the request on every other exit. The
// streaming request's own body still cannot be replayed
// (`DictationUploadDelegate`) — the fallback is a second, separate request.
//
// **The rules**, shared with the Python and Node SDKs' versions of the same
// fallback:
// 1. Every audio byte handed to the streaming upload is copied, from the first.
// 2. Only `413` with `error_code == "audio_too_large"` triggers it
//    (`LiveCapExceeded`); every other failure surfaces exactly as before.
// 3. On the trigger, the capture keeps being read — the 413 can arrive while
//    the user is still talking — until the recording ends (key up, or the
//    auto-release just before the 20-minute cap).
// 4. The whole copy goes to `/v1/transcribe` once, with the same `config` JSON
//    and audio part, and its response is treated exactly like a streamed one.
//    If it fails, its own error is what surfaces.
// 5. The copy is bounded (`SyncSTTLimits.maxBufferedAudioBytes`); past it the
//    copy is dropped and the fallback fails cleanly.
// 6. A cancel drops everything: no fallback request.
// 7. The drain is recording time, with no timeout of its own; the buffered
//    request gets the normal idle timeout.

/// The streaming route refused the recording for running past its cap — the
/// fallback's one trigger. Thrown by `send`, caught by `transcribe`, and never
/// seen outside this type: if the fallback can't run, the error that surfaces is
/// the fallback's own.
struct LiveCapExceeded: Error {}

extension AssemblyAITranscriber {
  /// The dictation API's **buffered** route, relative to `baseURL`: the whole
  /// recording in one body, read in full before transcription starts. Reached
  /// only from `transcribe`'s `LiveCapExceeded` catch — see `transcribePath`.
  static let bufferedTranscribePath = "v1/transcribe"

  /// The streaming route's documented answer to a recording past its cap: `413`
  /// with `error_code: "audio_too_large"`. Both halves, because the status
  /// alone is not specific: a `413` carrying anything else is surfaced as the
  /// error it is.
  static func isLiveCapRefusal(_ response: URLResponse, body: Data) -> Bool {
    guard (response as? HTTPURLResponse)?.statusCode == 413 else { return false }
    let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: body)
    return parsed?.errorCode == "audio_too_large"
  }

  /// Reads the capture feed to its end, handing every frame to the streaming
  /// upload (`live`) and keeping a copy for the fallback. Returns the copy, or
  /// nil if it would have passed `cap` — at which point it was dropped, freeing
  /// the memory then rather than at release.
  ///
  /// This is what lets the recording outlive the streaming request. The body
  /// producer that consumes `live` is torn down the moment that request ends,
  /// and when it read the capture feed directly that teardown ended the feed
  /// too, so everything said after a mid-recording `413` was dropped on the
  /// floor. Now only `live` ends; this keeps reading, and `live`'s yields become
  /// no-ops.
  ///
  /// No lock: the copy is a local of this one task, returned by value. Copying a
  /// frame here costs the upload's task an append, and nothing at all on the
  /// capture's delivery queue — the lock the 2026-09-08 rule protects.
  ///
  /// Cancellation ends it like the end of the feed (and ends the feed with it),
  /// so `transcribe`'s implicit cancel on every non-fallback exit is what
  /// releases the copy and the capture, as the body producer's cancel did before.
  static func relay(
    _ frames: AsyncStream<Data>, to live: AsyncStream<Data>.Continuation, keepingAtMost cap: Int
  ) async -> Data? {
    defer { live.finish() }
    var copy: Data? = Data()
    for await frame in frames {
      live.yield(frame)
      guard let kept = copy?.count else { continue }
      if kept + frame.count > cap {
        copy = nil
      } else {
        copy?.append(frame)
      }
    }
    return copy
  }

  /// Sends the whole recording to the buffered route — the fallback's single
  /// request — and returns its body for `transcribe` to decode exactly as it
  /// decodes a streamed response (same rewrite choice, same fallback to `text`,
  /// same paste and history downstream).
  ///
  /// `recording` is `relay`'s result, so by the time this runs the capture has
  /// ended: key up, the session's auto-release, or a cancel.
  func sendBuffered(
    _ recording: Data?, config: Data, apiKey: String, boundary: String, sampleRate: Int
  ) async throws -> Data {
    // A cancel during the drain ended the feed early, so `recording` is a
    // truncated copy of something the user discarded. Cancel means cancel.
    try Task.checkCancellation()
    guard let recording else {
      Self.log.error(
        "buffered fallback abandoned: the recording passed \(bufferedAudioByteCap, privacy: .public) bytes")
      throw AssemblyAIError.recordingTooLarge
    }
    var request = makeRequest(path: Self.bufferedTranscribePath, apiKey: apiKey, boundary: boundary)
    request.httpBody = DictationMultipart.bufferedBody(config: config, audio: recording, boundary: boundary)
    let clock = ContinuousClock()
    let start = clock.now
    let (data, response) = try await transport.data(for: request)
    Self.log.info(
      """
      dictation buffered round-trip \
      audioMs=\(SyncSTTLimits.durationMs(ofPCMBytes: recording.count, rate: sampleRate), privacy: .public) \
      postSpeechMs=\((clock.now - start).milliseconds, format: .fixed(precision: 0), privacy: .public)
      """)
    try Self.requireSuccess(response, body: data)
    return data
  }
}
