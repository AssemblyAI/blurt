/// Decides where each trigger command goes while the experimental read-aloud
/// switch is on: to the dictation session, or to reading the selection aloud.
/// It is a pure state machine. The app's `SelectionSpeechRouter` carries out the
/// actions it returns (the AX read, the speech task, the gate resets), the same
/// split as `DictationKeyRouter` under `DictationKeyTap`.
///
/// **Deciding** between dictating and speaking needs an Accessibility read of
/// the selection, so a press first waits in `.deciding`. Commands arriving in the
/// meantime (a quick release, a ⌘C combo's cancel) are held and replayed in order
/// once the read returns. That keeps the session's FIFO order either way.
///
/// **Speech follows the gate's tap/hold semantics, like dictation.** A tap
/// latches the gate, so speech runs until the next tap. A hold speaks until the
/// release. A combo that cancels the press cancels the speech, because right-⌘ + C
/// over a selection is a copy, not a request to hear it. Any key command ends a
/// read that is playing.
///
/// **This owns every "the gate is stale" decision.** A dictation that ends
/// without a key event leaves the gate latched, and so does a read that ends on
/// its own. Each asks for a different reset: `.syncGateAfterSession` goes through
/// the tap's recovery path, while `.resetGate` just clears it, because no
/// recording is involved.
public struct SelectionSpeechRouting: Sendable {
  public enum Action: Sendable, Equatable {
    case forward(DictationSession.Command)
    /// Start the Accessibility read. Its result comes back through `selectionResolved`.
    case readSelection
    case speak(String)
    case stopSpeech
    /// A dictation ended without a key event: `DictationKeyTap.syncAfterTerminalPhase`.
    case syncGateAfterSession
    /// A read ended on its own: clear the gate with no recording discarded.
    case resetGate
  }

  private enum Mode: Sendable, Equatable {
    case passthrough
    case deciding(pending: [DictationSession.Command])
    case speaking
  }

  private var mode = Mode.passthrough

  public init() {}

  public mutating func submit(_ command: DictationSession.Command, readAloudEnabled: Bool) -> [Action] {
    switch mode {
    case .passthrough:
      guard command == .press, readAloudEnabled else { return [.forward(command)] }
      mode = .deciding(pending: [])
      return [.readSelection]
    case .deciding(var pending):
      pending.append(command)
      mode = .deciding(pending: pending)
      return []
    case .speaking:
      // A recovery reset still reaches the session, where it can only cancel a
      // live recording, and there isn't one.
      mode = .passthrough
      return command == .cancelRecording ? [.stopSpeech, .forward(command)] : [.stopSpeech]
    }
  }

  public mutating func selectionResolved(_ selection: String?) -> [Action] {
    guard case .deciding(let pending) = mode else { return [] }
    guard let selection else {
      mode = .passthrough
      return ([.press] + pending).map(Action.forward)
    }
    // The press was already over before the read returned: a combo cancelled
    // it, or a hold was released. Neither one asked to hear anything.
    guard pending.isEmpty else {
      mode = .passthrough
      return []
    }
    mode = .speaking
    return [.speak(selection)]
  }

  /// The read ended on its own, or failed. The caller must not report a read it
  /// stopped itself: a key stop has already moved on, and a newer read may be
  /// playing.
  public mutating func speechFinished() -> [Action] {
    guard mode == .speaking else { return [] }
    mode = .passthrough
    return [.resetGate]
  }

  /// A dictation reached a terminal phase. The gate is only this router's to
  /// sync while commands are going to the session. Otherwise a read or a
  /// decision owns it, and the earlier dictation's end must not reset it.
  public func sessionReachedTerminalPhase() -> [Action] {
    mode == .passthrough ? [.syncGateAfterSession] : []
  }
}
