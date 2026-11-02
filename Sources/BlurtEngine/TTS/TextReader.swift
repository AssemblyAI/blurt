#if os(macOS)
  /// Reads any text aloud in the user's read-aloud voice and speed — the
  /// transcript sheet's Play on a task result (meeting notes, a summary), which
  /// has no audio of its own. The same streaming TTS as the read-aloud key,
  /// without the skip-jargon rewrite (a task result is already plain prose)
  /// and without keeping a clip (the text is already saved with its entry).
  ///
  /// Runs until the speech has played; cancelling the task stops it at once.
  public struct TextReader: Sendable {
    private let speaker: any ReadAloudSpeaker

    public init() {
      self.init(speaker: SelectionSpeaker())
    }

    init(speaker: any ReadAloudSpeaker) {
      self.speaker = speaker
    }

    public func read(_ text: String) async throws {
      try await speaker.speak(text, style: ReadAloudStyleStore().style.verbatim, onLevel: nil)
    }
  }
#endif
