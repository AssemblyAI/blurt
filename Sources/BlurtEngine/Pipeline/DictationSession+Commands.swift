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
    // A cancel acts *now*, not when its turn comes up. The consumer below is
    // serial by design, so a `.cancel` submitted during a press waits for that
    // press to finish before `cancel()` even runs — and since `MicCapture.start()`
    // holds until the mic is delivering audio, on a Bluetooth route that is
    // seconds of an Escape that appears to do nothing. Recording the intent and
    // preempting the press here is what `cancel()` does for a live pipeline;
    // this gives the submitted door the same reach. The command is still yielded
    // in order, and still executes in order — `performCancel` is idempotent
    // against a cancel already consumed.
    if command == .cancel { requestCancel() }
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

  /// Set synchronously by either entry point — `cancel()` or `submit(.cancel)` —
  /// before taking a queue turn, so a cancel arriving while a queued release
  /// hasn't yet claimed `.transcribing` deterministically wins: `performRelease`
  /// consumes the request after its `mic.stop()`, before any pipeline is spawned.
  /// (A release that already claimed `.transcribing` is handled by `cancel()`'s
  /// synchronous path instead.) `performCancel` clears it whether or not it was
  /// consumed early, and `performPress` consumes it before claiming `.recording`
  /// so a cancel during the mic bring-up never yields a phantom recording.
  ///
  /// Internal, like `pipelineTask` and `autoReleaseTask`, because the moment the
  /// request is recorded is otherwise unobservable: a test landing a cancel
  /// against an in-flight press has to know it was recorded before it releases
  /// that press, and the alternative — draining a fixed number of `Task.yield()`s
  /// and hoping — is a budget that drains the calling task, not this actor.
  nonisolated var cancelRequested: Bool {
    get { cancelState.withLock { $0.requested } }
    set { cancelState.withLock { $0.requested = newValue } }
  }

  /// Handle to the press currently on the command queue, so a cancel can
  /// **preempt** the mic bring-up rather than queue behind it — the same
  /// treatment `pipelineTask` already gives `.transcribing`/`.injecting`.
  /// `MicCapture.start()` can hold for seconds on a Bluetooth route, and
  /// `MicLiveness.waitUntilLive` already returns early on task cancellation, so
  /// cancelling this handle unblocks it at once.
  ///
  /// Beside `requested` under the same lock, and for the same reason: reachable
  /// from `nonisolated` `submit(_:)`, whose whole job is to act without waiting
  /// for a turn on an actor the in-flight press is holding.
  nonisolated var inFlightPress: Task<Void, Never>? {
    get { cancelState.withLock { $0.press } }
    set { cancelState.withLock { $0.press = newValue } }
  }

  /// Records the cancel intent and preempts an in-flight press, synchronously
  /// and from any isolation. The one place both doors funnel through, so
  /// `submit(.cancel)` and `cancel()` can't drift apart.
  nonisolated func requestCancel() {
    let press = cancelState.withLock { state -> Task<Void, Never>? in
      state.requested = true
      return state.press
    }
    press?.cancel()
  }

  /// Drops the press handle if it is still `task`'s — a later press may already
  /// have claimed the slot, and clearing that one would let its bring-up run
  /// un-cancellable.
  nonisolated func clearInFlightPress(_ task: Task<Void, Never>) {
    cancelState.withLock { if $0.press == task { $0.press = nil } }
  }

  public func cancel() async {
    // A cancel that lands once `.transcribing` is claimed — while the release
    // is still inside mic.stop(), or later with the transcribe→inject task in
    // flight — tears the pipeline down (a nil or finished handle is a no-op)
    // and claims the phase, so neither the release (which re-checks the phase
    // after mic.stop()) nor the cancelled pipeline can overwrite it back to
    // .idle. Synchronous (no suspension), so it acts immediately rather than
    // queueing behind the pipeline's progress.
    if phase == .transcribing || phase == .injecting {
      // Cancel but keep the handle so `awaitPipeline()` can join the cancelled task.
      pipelineTask?.cancel()
      setPhase(.cancelled)
      return
    }
    // `.connecting` gets the same treatment, for the same reason: it is in-flight
    // work with a handle to cancel. The press is suspended inside
    // `MicCapture.start()`'s liveness wait, which honors task cancellation and
    // returns at once — so this unblocks a bring-up that could otherwise hold for
    // `MicLiveness.bluetoothTimeout`. `start()` tears the recorder down and throws
    // `CancellationError`, which `performPress` maps to `.cancelled` — already
    // claimed here, so the pill answers the Escape immediately.
    if phase == .connecting {
      requestCancel()
      setPhase(.cancelled)
      return
    }
    // Record the intent before taking a queue turn: a release queued ahead of
    // our turn consumes it the moment its mic.stop() returns (no pipeline is
    // ever spawned), and a press ahead in the queue is followed by our own
    // turn, which ends the freshly started recording. Either way the cancel is
    // honored in arrival order, never dropped.
    requestCancel()
    await enqueue { await self.performCancel() }
  }

  private func performCancel() async {
    // Our turn is the cancel — clear the request whether or not an earlier
    // release already consumed it.
    cancelRequested = false
    guard phase == .recording else { return }
    await stopAndCancel()
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
