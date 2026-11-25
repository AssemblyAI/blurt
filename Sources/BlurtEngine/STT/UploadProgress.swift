import AssemblyAI
import Foundation
import Synchronization
import os

// The chunked upload's instrumentation, split from `AssemblyAITranscriber.swift`
// to stay within the lint file-length budget (like the `AssemblyAI` module's `Dictation/` files,
// which took the JSON contract). What the body producer measures on its way
// past, and the per-task delegate that reports it.

/// What the body producer knows and the request's log line needs: how much
/// audio has actually been streamed, and when the last frame went out.
///
/// Shared through a `Mutex` rather than returned, because the producer runs as
/// its own task inside the body stream and outlives no single call — the
/// response handler reads these back once the upload completes. `lastFrameAt`
/// is nil only for a recording that produced no frames at all.
final class UploadProgress: Sendable {
  private struct State {
    var audioBytes = 0
    var lastFrameAt: ContinuousClock.Instant?
  }

  /// A reference type wrapping a `Mutex`, rather than a `Mutex<Struct>` passed
  /// around directly: `Mutex` is non-copyable, so it cannot cross a function
  /// parameter or be captured by the escaping body-producer closure.
  private let state = Mutex(State())

  var audioBytes: Int { state.withLock { $0.audioBytes } }
  var lastFrameAt: ContinuousClock.Instant? { state.withLock { $0.lastFrameAt } }

  /// Accounts one delivered frame. The timestamp is taken here, at the moment
  /// the frame is handed to the upload — the closest thing the client has to
  /// "the user stopped talking" for the final frame.
  func recordFrame(bytes: Int) {
    let now = ContinuousClock().now
    state.withLock { progress in
      progress.audioBytes += bytes
      progress.lastFrameAt = now
    }
  }
}

extension AssemblyAITranscriber {
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
  static func logServerMetrics(_ response: DictationResponse) {
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
