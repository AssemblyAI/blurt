/// One turn as the realtime API last described it. A later update with the
/// same `order` replaces it — partials grow, then the final lands.
public struct RealtimeTurn: Sendable, Equatable {
  public let order: Int
  public let transcript: String
  /// `end_of_turn`: the speaker finished this turn and the text is settled.
  public let isFinal: Bool
  /// `speaker_label`, with speaker labels on: "A", "B", …
  public let speaker: String?

  public init(order: Int, transcript: String, isFinal: Bool, speaker: String?) {
    self.order = order
    self.transcript = transcript
    self.isFinal = isFinal
    self.speaker = speaker
  }
}
