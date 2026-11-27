public import AssemblyAI
public import BlurtEngine

extension RealtimeTranscriber {
  /// AssemblyAI's notetaker streaming model (`assemblyai-stt-3-7-realtime`),
  /// built for meeting recordings and live `speaker_labels` rather than the
  /// voice-agent default.
  static let speechModel = "assemblyai-stt-3-7-realtime"

  /// A session as Blurt opens one: the user's key, the notetaker streaming
  /// model, and Blurt's User-Agent.
  public static func blurt(apiKey: String) -> RealtimeTranscriber {
    RealtimeTranscriber(apiKey: apiKey, speechModel: speechModel, userAgent: UserAgent.current)
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
