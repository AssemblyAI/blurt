#if os(macOS)
  /// Takes turns on `NSPasteboard.general` between Blurt's two borrowers of it:
  /// the paste (`KeyInjector`: write the transcript, ⌘V, settle, restore) and the
  /// read-aloud copy fallback (`SelectionCopy`: snapshot, ⌘C, poll, restore).
  ///
  /// Each borrows the user's clipboard and promises to put it back, and each
  /// judges "put it back" by the change count its own write left. Interleaved,
  /// both promises break (issue #341): a ⌘C inside a paste's 400 ms settle
  /// snapshots the *transcript* as the user's clipboard and restores that, after
  /// which the paste's restore sees a moved count and skips — the user's
  /// clipboard is gone. A paste's restore landing mid-poll makes the copy give up
  /// without watching for its ⌘C's late answer, which then overwrites the
  /// restored clipboard. One turn at a time, in arrival order, and neither can
  /// happen.
  ///
  /// The queue is a chain of tasks rather than a lock, the shape `KeyInjector`'s
  /// paste chain already had: each turn waits on the one before, and a turn that
  /// fails or is cancelled still ends, so the next one runs.
  actor ClipboardTurns {
    /// The one queue production shares: both borrowers touch the same global
    /// pasteboard, so they must wait on the same turns. Tests that need no
    /// cross-borrower ordering make their own.
    static let shared = ClipboardTurns()

    /// The last turn queued; the next one waits for it.
    private var tail: Task<Void, Never>?

    /// Queues `work`, then keeps the turn held through `settle` (handed `work`'s
    /// result) so a borrower can return to its caller while its clipboard is
    /// still lent out. A `work` that throws ends the turn without settling.
    ///
    /// Returns `work`'s task, for the caller to await (and cancel), and the whole
    /// turn's, for whoever must wait out the settle too.
    func enqueue<Value: Sendable>(
      _ work: @escaping @Sendable () async throws -> Value,
      thenHolding settle: @escaping @Sendable (Value) async -> Void
    ) -> (result: Task<Value, any Error>, turn: Task<Void, Never>) {
      let previous = tail
      let result = Task {
        await previous?.value
        return try await work()
      }
      let turn = Task {
        guard let value = try? await result.value else { return }
        await settle(value)
      }
      tail = turn
      return (result, turn)
    }

    /// Runs `work` in its own turn, which ends when `work` returns.
    func run<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value {
      let previous = tail
      let result = Task {
        await previous?.value
        return await work()
      }
      tail = Task { _ = await result.value }
      return await result.value
    }
  }
#endif
