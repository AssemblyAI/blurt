/// One update from a live transcription session: a turn, partial while it is
/// being spoken, then final. Provider-neutral; a provider package maps its own
/// (`BlurtAssemblyAI` from AssemblyAI's `RealtimeTurn`).
public struct LiveTurn: Sendable, Equatable {
  /// The turn's place in the session: a final replaces the partial of the
  /// same order, and a repeated final replaces the earlier one.
  let order: Int
  let transcript: String
  let isFinal: Bool
  /// The speaker's label, when the session tells speakers apart.
  let speaker: String?

  /// A turn as the provider's session reported it.
  public init(order: Int, transcript: String, isFinal: Bool, speaker: String?) {
    self.order = order
    self.transcript = transcript
    self.isFinal = isFinal
    self.speaker = speaker
  }
}
