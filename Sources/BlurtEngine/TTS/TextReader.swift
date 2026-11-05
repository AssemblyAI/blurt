#if os(macOS)
  import Synchronization

  /// Reads any text aloud in the user's read-aloud voice and speed — the
  /// transcript sheet's Play on a task result (meeting notes, a summary), which
  /// has no audio of its own. The same streaming TTS as the read-aloud key,
  /// without the skip-jargon rewrite (a task result is already plain prose)
  /// and without keeping a clip (the text is already saved with its entry).
  ///
  /// Runs until the speech has played; cancelling the task stops it at once.
  /// The speech is generated as it plays, so there's a wait before the first
  /// word: `onStart` says when it's over, for a caller showing "Preparing…".
  public struct TextReader: Sendable {
    private let speaker: any ReadAloudSpeaker

    public init() {
      self.init(speaker: SelectionSpeaker())
    }

    init(speaker: any ReadAloudSpeaker) {
      self.speaker = speaker
    }

    /// Reads `text` aloud. `onStart` runs once, when the first audio plays —
    /// the speaker's first level reading — and not at all if none does.
    public func read(_ text: String, onStart: (@Sendable () -> Void)? = nil) async throws {
      let onLevel: (@Sendable (Float) -> Void)? = onStart.map { onStart in
        let once = Once()
        return { _ in if once.claim() { onStart() } }
      }
      try await speaker.speak(text, style: ReadAloudStyleStore().style.verbatim, onLevel: onLevel)
    }
  }

  /// True from `claim()` the first time only, from any thread: the speaker
  /// reports levels off the main actor, many times a second.
  private final class Once: Sendable {
    private let claimed = Mutex(false)

    func claim() -> Bool {
      claimed.withLock { claimed in
        defer { claimed = true }
        return !claimed
      }
    }
  }
#endif
