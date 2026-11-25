#if os(macOS)
  /// What reads text aloud for `SelectionSpeechRouter`: `SelectionSpeaker` in
  /// production, a stand-in under UI testing (no network, no audio). Both calls
  /// run until the speech has played; cancelling the task stops it.
  public protocol ReadAloudSpeaker: Sendable {
    func speak(_ text: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?) async throws
    func answer(
      _ request: String, about selection: String, style: ReadAloudStyle, onLevel: (@Sendable (Float) -> Void)?
    ) async throws
  }
#endif
