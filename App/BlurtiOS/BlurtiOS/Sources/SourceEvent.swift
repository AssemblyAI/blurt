/// Something the microphone said about itself, after the fact. A failure is
/// what a start throws; an event is what happens to a microphone already open.
nonisolated enum SourceEvent: Sendable, Equatable {
  /// iOS took the input — a call, Siri, another app recording. `reason` is
  /// the system's name for why (`audioDeviceInUseByAnotherClient`, …).
  case interrupted(reason: String)
  case interruptionEnded
  /// The capture session failed while running; `code` is the system's.
  case runtimeError(code: Int)
  /// The audio route changed under the microphone: `input` names the port
  /// now feeding it (`BluetoothHFP`, `MicrophoneBuiltIn`), nil when none does.
  case routeChanged(reason: String, input: String?)
  /// The silence watchdog: an open utterance heard `UtteranceFeed.silenceSeconds`
  /// of digital silence, which no live route delivers.
  case silent
}
