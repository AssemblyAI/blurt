#if os(macOS)
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
    /// the speaker's first level reading above silence — and not at all if
    /// none does. Not its first reading of any kind: the meter reports the
    /// silence before the first audio, and a final 0 however the read ends.
    @preconcurrency
    public func read(_ text: String, onStart: (@Sendable () -> Void)? = nil) async throws {
      let onLevel: (@Sendable (Float) -> Void)? = onStart.map { onStart in
        let once = OnceFlag()
        return { level in if level > 0, once.claim() { onStart() } }
      }
      try await speaker.speak(text, style: ReadAloudStyleStore().style.verbatim, onLevel: onLevel)
    }
  }
#endif
