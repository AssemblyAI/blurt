import Foundation
import os

extension DictationClient {
  /// The server's own account of the round trip, logged beside the client's.
  ///
  /// Three of the four numbers here have no client-side equivalent, which is
  /// the point: `postSpeechMs` says the dictation was slow, and
  /// `request_time_ms`/`sync_time_ms` say whether the time went to the STT
  /// upstream or to the rewrite. `audio_duration_ms` is the one overlap, and a
  /// *disagreement* with the client's `audioMs` is the signal — it means the
  /// upload was truncated, which nothing else distinguishes from a short
  /// utterance.
  ///
  /// `session_id` is the reason this exists at all: the reference asks callers
  /// to quote it when reporting a problem, and a request whose id was never
  /// recorded cannot be looked up afterwards. Public-privacy like every other
  /// field on these lines — it identifies the request, not the user, and a
  /// redacted id is an id nobody can quote.
  ///
  /// Every field is optional, so this logs `n/a` rather than skipping the line:
  /// "the service stopped sending `session_id`" is itself worth being able to
  /// see in a log.
  func logServerMetrics(_ response: DictationResponse) {
    func ms(_ value: Double?) -> String {
      value.map { unsafe String(format: "%.0f", $0) } ?? "n/a"
    }
    log.info(
      """
      dictation server session=\(response.sessionId ?? "n/a", privacy: .public) \
      audioMs=\(ms(response.audioDurationMs), privacy: .public) \
      requestMs=\(ms(response.requestTimeMs), privacy: .public) \
      sttMs=\(ms(response.syncTimeMs), privacy: .public)
      """
    )
  }
}
