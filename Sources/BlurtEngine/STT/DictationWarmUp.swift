import Foundation

// The dictation route's connection pre-warming, split from
// `AssemblyAITranscriber.swift` to stay within the lint file-length budget —
// the same reason `DictationWireTypes.swift` took the JSON contract and
// `DictationUploadMetrics.swift` took the instrumentation. Two members and a
// long "why", for a call whose whole job is to happen before anything needs it.
extension AssemblyAITranscriber {
  /// The route's own pre-warming endpoint: `GET /warm`, "an unauthenticated
  /// no-op" that answers `{"warm": "toasty"}`. Unversioned, unlike the transcribe
  /// path — it sits at the host root. `warmUp()` hit that bare root until
  /// 2026-09-11, which opened the same connection but asked the service for a
  /// page it never documented; this is the request it publishes for exactly this
  /// purpose.
  static let warmPath = "warm"

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
  /// A `GET` to `warmPath`, whose body is discarded — only the connection it
  /// leaves in the pool matters. The reference's two conditions for that pool
  /// hit to survive are both structural here: *same client* (this goes through
  /// the injected `transport`, which is the one `transcribe` uses) and *same
  /// host* (`baseURL`, so a data-zone override warms the zone it will call).
  public func warmUp() async {
    var request = URLRequest(url: baseURL.appending(path: Self.warmPath))
    request.httpMethod = "GET"
    request.timeoutInterval = 5
    let clock = ContinuousClock()
    let start = clock.now
    _ = try? await transport.data(for: request)
    let elapsedMs = (clock.now - start).milliseconds
    Self.log.info(
      "warm-up connect \(elapsedMs, format: .fixed(precision: 0), privacy: .public)ms")
  }
}
