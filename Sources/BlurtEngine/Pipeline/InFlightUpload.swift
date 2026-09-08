/// The dictation request opened at press: the task carrying it, and the channel
/// its `config` part is waiting on.
///
/// One value because they are one thing. A live request is always both a task
/// and an open context channel, and both end together — held as two independent
/// optionals on the session they were installed in one place and torn down in
/// three, and the teardowns had already drifted: one guarded that the handle was
/// still the caller's, the other did not, ten lines below a comment spelling out
/// that exact trap. Here "no channel without a task" holds by construction.
///
/// A value type, so the session's `upload` property is the single place the
/// request's existence is recorded; `DictationSession.cancelUpload()` is the one
/// door out.
struct InFlightUpload {
  /// The request itself. Kept accessible because `awaitUpload` has to compare it
  /// for identity — a later press installs its own, and clearing that one would
  /// strand a live request nothing can cancel.
  let task: Task<String, any Error>
  private var contextFeed: AsyncStream<TranscriptionContext?>.Continuation?

  init(task: Task<String, any Error>, contextFeed: AsyncStream<TranscriptionContext?>.Continuation) {
    self.task = task
    self.contextFeed = contextFeed
  }

  /// Hands the request the press-time context its `config` part is holding for,
  /// and closes the channel.
  ///
  /// Closing is part of sending, not a separate step: the producer writes its
  /// config part on receiving this, so a channel left open would hold the upload
  /// open with it.
  mutating func send(_ context: TranscriptionContext?) {
    contextFeed?.yield(context)
    contextFeed?.finish()
    contextFeed = nil
  }

  /// Abandons the request — a dictation that ended without a transcript must not
  /// leave one streaming, or the service transcribes audio nobody is waiting for.
  ///
  /// Both halves, because cancelling only the task is not enough: awaiting a
  /// `Task`'s value is not cancellation-aware, and a producer parked on a
  /// context that is no longer coming would wait regardless. Finishing an
  /// already-finished channel is a no-op, so this is safe to call twice.
  func abandon() {
    task.cancel()
    contextFeed?.finish()
  }
}
