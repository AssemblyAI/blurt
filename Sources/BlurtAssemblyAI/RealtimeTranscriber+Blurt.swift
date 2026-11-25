public import AssemblyAI
public import BlurtEngine

extension RealtimeTranscriber {
  /// A session as Blurt opens one: the user's key and Blurt's User-Agent.
  public static func blurt(apiKey: String) -> RealtimeTranscriber {
    RealtimeTranscriber(apiKey: apiKey, userAgent: UserAgent.current)
  }
}

extension LiveTurn {
  /// The engine's turn for one update from the realtime API.
  init(_ turn: RealtimeTurn) {
    self.init(order: turn.order, transcript: turn.transcript, isFinal: turn.isFinal, speaker: turn.speaker)
  }
}

extension LiveTranscript {
  /// Folds in one update from AssemblyAI's realtime API.
  public mutating func apply(_ turn: RealtimeTurn) {
    apply(LiveTurn(turn))
  }
}
