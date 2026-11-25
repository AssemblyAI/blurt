/// Which of a provider's models a chat request wants, named by the job rather
/// than by the model: the engine's LLM clients ask for a tier, and the provider
/// package picks the model it serves for it (`BlurtAssemblyAI` maps each to an
/// LLM Gateway model). So the engine names no provider's model, and a provider
/// can change its pick without the engine changing.
public enum ChatModelTier: Sendable, Equatable {
  /// A small, fast model for short jobs the user is waiting on: read-aloud's
  /// skip-jargon rewrite and its spoken answer (`ReadAloudLLM`). A provider
  /// serves it with at least a 32k-token context, which
  /// `ReadAloudLLM.answerSelectionCharacters` is sized to.
  case fast
  /// A larger model for writing, planning and reading a whole transcript: the
  /// file-transcript transforms (`TranscriptLLM`), the rewrite and compose keys
  /// (`SelectionRewriter`, `MessageComposer`) and the command planner
  /// (`VoiceCommandPlanner`). A provider serves it with a context long enough
  /// for hours of speech, so a recording's transcript fits whole.
  case capable
}
