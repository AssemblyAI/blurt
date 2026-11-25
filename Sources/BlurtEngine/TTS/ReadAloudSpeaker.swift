#if os(macOS)
  /// What reads text aloud for `SelectionSpeechRouter`: `SelectionSpeaker` in
  /// production, a stand-in under UI testing (no network, no audio). Both calls
  /// run until the speech has played; cancelling the task stops it.
  public protocol ReadAloudSpeaker: Sendable {
    func speak(_ text: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?) async throws
    func answer(
      _ request: String, about selection: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?
    ) async throws

    /// The voice `id` speaks with — the default for nil or an id the provider
    /// doesn't offer — to name it in the voice sample. Nil when the speaker
    /// can't say (a stand-in); the sample then says "your voice".
    func voice(for id: String?) -> ReadAloudVoice?
  }

  extension ReadAloudSpeaker {
    /// A stand-in names no voice.
    public func voice(for _: String?) -> ReadAloudVoice? { nil }
  }
#endif
