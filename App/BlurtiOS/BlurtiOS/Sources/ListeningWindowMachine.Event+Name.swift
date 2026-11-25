import BlurtiOSCore

extension ListeningWindowMachine.Event {
  /// The event's name for the transition log: the case, and the reason where one rides along.
  var name: String {
    switch self {
    case .openRequested(let inForeground):
      inForeground ? "openRequested" : "openRequested(background)"

    case .opened:
      "opened"

    case .openFailed(_, let reason):
      "openFailed(\(reason.rawValue))"

    case .utteranceStarted:
      "utteranceStarted"

    case .utteranceEnded:
      "utteranceEnded"

    case .interruptionBegan(_, let reason):
      "interruptionBegan(\(reason.rawValue))"

    case .interruptionEnded(_, let shouldResume):
      shouldResume ? "interruptionEnded" : "interruptionEnded(noResume)"

    case .foregrounded(let turnedOff):
      turnedOff ? "foregrounded(turnedOff)" : "foregrounded"

    case .resumed:
      "resumed"

    case .resumeFailed(_, let reason):
      "resumeFailed(\(reason.rawValue))"

    case .sourceDied(_, let reason):
      "sourceDied(\(reason.rawValue))"

    case .mediaReset:
      "mediaReset"

    case .expired:
      "expired"

    case .closeRequested:
      "closeRequested"

    case .closed:
      "closed"

    case .idleChanged(_, let idle):
      "idleChanged(\(idle.rawValue))"

    case .windowMinutesChanged(let minutes):
      "windowMinutesChanged(\(minutes))"
    }
  }
}
