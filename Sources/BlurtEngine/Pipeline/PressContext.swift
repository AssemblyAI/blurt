import Synchronization

/// The press-time Accessibility read, and the one place it is published: waited
/// on with a budget when the request opens, peeked at afterwards.
///
/// It exists because the streaming route split one reader into two with
/// different deadlines. `config` leads the request body, so
/// `DictationSession.startUpload` cannot wait past `contextWaitBudget` for a
/// cross-process read without holding the audio back — and that budget is spent
/// against a read that has only had the mic bring-up to finish in, not the whole
/// recording as it did when the wait lived on the release path. Two readers are
/// left needing the same value on a *later* deadline:
///
/// - the paste separator (`inject`, via `priorText`/`windowTitle`), and
/// - the remember-this-dictation decision, which is the one that matters. A nil
///   context reads as "not a password field" (`TranscriptionContext.isEmpty`
///   documents why the flag cannot survive being collapsed to nil), so a
///   dictation into a secure field would be recorded into `recentDictations` and
///   replayed in `stt_prompt` on every later dictation this launch.
///   That is precisely the leak `targetIsSecure` exists to prevent, and a merely
///   slow target — `FocusCapture` makes ~6 serial AX round trips, each capped at
///   ~1 s — must not be enough to open it.
///
/// So `wait(within:clock:)` is the deadline-bound read the upload needs and
/// `resolved` is the peek the release path needs, over one stored value. Holding
/// both here rather than beside each other on the actor is what makes the
/// ordering unforgeable: `store(resolved:)` writes the value *then* publishes to
/// the stream, so a waiter that sees the stream finish can never find the value
/// missing, and no call site can get that backwards.
///
/// `pressKnown` is the other half of the same problem, and needs no
/// synchronization: it is what the actor already knew at press — key terms and
/// the recent-dictation ring, no focus signals — set once and never written
/// again. It used to be discarded along with the field text whenever the budget
/// was missed, because the same `TranscriptionContext` carried both. Kept apart,
/// a timeout costs the request only what actually failed to arrive, so
/// `keyterms_prompt` and the recent-dictation turns still reach the wire.
///
/// A `Mutex`-backed reference type for the same reason `UploadProgress` is one:
/// the writer is a Dispatch block that cannot touch the actor, and `Mutex` is
/// non-copyable so it cannot be passed or captured directly.
final class PressContext: Sendable {
  private struct State {
    var resolved: TranscriptionContext?
    /// Handed out by the first `wait(within:clock:)` and nil after, so the
    /// take-it-out-in-the-same-turn-you-read-it discipline the actor used to
    /// carry in a comment is now a property of the type. An `AsyncStream` cannot
    /// be re-iterated once a cancelled `firstValue` group has dropped it, which
    /// is exactly why `resolved` exists alongside it.
    var stream: AsyncStream<TranscriptionContext?>?
  }

  /// What the actor already knew at press. The config's fallback when the read
  /// misses its budget.
  let pressKnown: TranscriptionContext?

  private let state: Mutex<State>
  private let feed: AsyncStream<TranscriptionContext?>.Continuation

  init(pressKnown: TranscriptionContext?) {
    self.pressKnown = pressKnown
    let (stream, feed) = AsyncStream.makeStream(
      of: TranscriptionContext?.self, bufferingPolicy: .bufferingNewest(1))
    self.feed = feed
    self.state = Mutex(State(resolved: nil, stream: stream))
  }

  /// The read, once the capture queue has it. Nil until then — and nil forever
  /// for a genuinely hung target, which is the case the release-side readers
  /// cannot do anything about either.
  var resolved: TranscriptionContext? { state.withLock { $0.resolved } }

  /// Publishes the finished read. The value lands before the stream does, so
  /// `wait` cannot outrun `resolved`.
  func store(resolved context: TranscriptionContext?) {
    state.withLock { $0.resolved = context }
    feed.yield(context)
    feed.finish()
  }

  /// The read if it arrives within `budget`, else nil — the bounded wait
  /// `startUpload` opens the request behind. Answers nil to a second caller:
  /// the stream is consumed once, and `resolved` is how anyone later asks.
  func wait(within budget: Duration, clock: any Clock<Duration>) async -> TranscriptionContext? {
    let taken: AsyncStream<TranscriptionContext?>? = state.withLock {
      let stream = $0.stream
      $0.stream = nil
      return stream
    }
    guard let taken else { return nil }
    return await Self.firstValue(of: taken, within: budget, clock: clock)
  }

  /// The first value of `stream`, or nil once `budget` elapses on `clock`.
  ///
  /// Both racers respond to cancellation (an `AsyncStream` iteration ends when
  /// its task is cancelled, unlike awaiting a `Task.value`, which would leave
  /// the group joined to a hung AX read), so the losing child always winds down
  /// and the group drains. Internal rather than private so `ContextWaitTests`
  /// can exercise the race on its own; it was a static on `DictationSession`
  /// before the wait moved in here with the value it waits for.
  static func firstValue(
    of stream: AsyncStream<TranscriptionContext?>, within budget: Duration,
    clock: any Clock<Duration>
  ) async -> TranscriptionContext? {
    await withTaskGroup(of: TranscriptionContext?.self) { group in
      group.addTask {
        for await value in stream { return value }
        return nil
      }
      group.addTask {
        try? await clock.sleep(for: budget)
        return nil
      }
      let winner = await group.next() ?? nil
      group.cancelAll()
      return winner
    }
  }
}
