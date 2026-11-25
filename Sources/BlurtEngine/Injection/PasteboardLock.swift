#if os(macOS)
  import Synchronization

  /// One turn at a time on a pasteboard, for Blurt's own save → write → restore
  /// sequences: `KeyInjector`'s paste (write, ⌘V, settle, restore) and
  /// `SelectionCopy`'s copy (snapshot, ⌘C, poll, restore). Each assumes nothing
  /// else of Blurt's moves the clipboard between its snapshot and its restore.
  /// Interleaved, a copy inside a paste's settle window snapshotted the transcript
  /// as "the user's clipboard" and put it back for good, and a paste's restore
  /// landing mid-copy made the copy give up with its ⌘C still in flight, so the
  /// app's late answer overwrote the user's clipboard.
  ///
  /// Turns are granted in the order they were asked for. The pasteboard owns its
  /// lock (`ClipboardAccess.lock`, `CopyPasteboard.lock`): the system pasteboard's
  /// is one process-wide `system`, while a test's in-memory fake brings its own,
  /// so parallel tests never queue behind each other.
  final class PasteboardLock: Sendable {
    /// A held turn. Ending it twice is harmless.
    struct Turn: Sendable {
      private let continuation: AsyncStream<Never>.Continuation

      init(continuation: AsyncStream<Never>.Continuation) {
        self.continuation = continuation
      }

      func end() { continuation.finish() }
    }

    /// `NSPasteboard.general`'s lock, shared by every `SystemClipboard`.
    static let system = PasteboardLock()

    /// The last turn asked for; it completes when that turn ends.
    private let tail = Mutex<Task<Void, Never>?>(nil)

    /// Waits for every earlier turn to end, then hands back this one. The
    /// caller must `end()` it on every path — a turn never ended holds the
    /// pasteboard for good.
    func acquire() async -> Turn {
      let (ended, continuation) = AsyncStream<Never>.makeStream()
      let mine = Task {
        for await _ in ended {
          // Never yields: the stream only finishes, when the turn ends.
        }
      }
      let previous = tail.withLock { tail in
        defer { tail = mine }
        return tail
      }
      await previous?.value
      return Turn(continuation: continuation)
    }
  }
#endif
