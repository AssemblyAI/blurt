extension DictationSession {
  /// One host-initiated pipeline command, for `submit(_:)`. Mirrors the four
  /// async methods one-to-one; see each method's doc for semantics.
  public enum Command: Sendable {
    case press
    case release
    case cancel
    case cancelRecording
  }

  /// Synchronous, fire-and-forget command submission for callback-shaped hosts
  /// (an event tap, a UI action) that can't `await` — and, crucially, can't
  /// spawn a `Task` per callback without losing ordering: independently created
  /// tasks carry no FIFO guarantee, so a recovery cancel could overtake the
  /// press it was meant to cancel, no-op on a still-idle session, and strand
  /// the eventual recording with no key-up ever arriving. Commands submitted
  /// from one thread run in exactly the order they were submitted (they feed a
  /// single serial consumer — see `init`). Hosts that can `await` may call the
  /// async methods directly instead; the two styles hit the same serial queue.
  public nonisolated func submit(_ command: Command) {
    commandFeed.yield(command)
  }

  /// Executes one submitted command by delegating to the public method it
  /// mirrors, so `submit` and direct calls share every guard and race rule.
  func run(_ command: Command) async {
    switch command {
    case .press: await press()
    case .release: await release()
    case .cancel: await cancel()
    case .cancelRecording: await cancelRecording()
    }
  }

  /// Cancels only a live *recording* — the narrow cancel for synthetic,
  /// state-recovery callers (the event tap's disabled-tap recovery and trigger
  /// rebinding), whose intent is "the key events ending this capture may be
  /// lost". Unlike `cancel()`, it never tears down a `.transcribing`/`.injecting`
  /// pipeline and never preempts a queued release: reaching this op's turn with
  /// the capture already ended (or ending) means a release happened
  /// legitimately (e.g. the auto-release cap fired while the gate was still
  /// latched), and discarding that transcript would lose the user's words.
  public func cancelRecording() async {
    await enqueue { await self.performCancelRecording() }
  }

  private func performCancelRecording() async {
    guard phase == .recording else { return }
    await stopAndCancel()
  }
}
