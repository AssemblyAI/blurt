import Synchronization

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
