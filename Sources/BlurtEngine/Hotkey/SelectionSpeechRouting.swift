/// Decides where each trigger command goes while the experimental read-aloud
/// switch is on: to the dictation session, to reading the selection aloud, or
/// to asking about the selection. It is a pure state machine. The app's
/// `SelectionSpeechRouter` carries out the actions it returns (the AX read, the
/// hold timer, the speech task, the gate resets), the same split as
/// `DictationKeyRouter` under `DictationKeyTap`.
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
/// **With asking on (`SelectionAskStore`), a hold over a selection asks about
/// it instead.** A tap still reads: the gate's `.latch` is the moment a tap is
/// known (`keyLatched`). A key still down `askHoldDelay` after the press is a
/// hold, and only then does the mic open, through the session's hand-back press,
/// so a tap never pays for a recording. (Opening the mic is not free: on AirPods
/// it switches the link to its headset mode, which the read would then play
/// through.) Letting go ends the request, whether the gate saw that as a hold's
/// stop or a short hold's latch. The transcript comes back as `.handedBack`, and
/// the answer is read aloud. A request with nothing said reads the selection
/// instead, which is also how a hold-only trigger still reads at all.
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
    /// Call `holdElapsed` after `askHoldDelay`, unless a newer press restarts it.
    case startHoldTimer
    case speak(String)
    /// Answer the spoken `request` about `selection`, aloud.
    case answer(request: String, selection: String)
    case stopSpeech
    /// A dictation ended without a key event: `DictationKeyTap.syncAfterTerminalPhase`.
    case syncGateAfterSession
    /// A read ended on its own: clear the gate with no recording discarded.
    case resetGate
  }

  /// How long the key must stay down over a selection to count as a hold. Well
  /// under the gate's 1 s tap/hold threshold, because the user waits this long
  /// (plus the mic bring-up) for the start chime before speaking; a deliberate
  /// tap is over long before it.
  public static let askHoldDelay = Duration.milliseconds(350)

  private enum Mode: Sendable, Equatable {
    case passthrough
    /// The selection read is in flight. For a press that may ask, the tap and
    /// hold signals that land meanwhile are kept too.
    case deciding(pending: [DictationSession.Command], asks: Bool, latched: Bool, held: Bool)
    /// A selection is in hand and the key is still down: a tap reads it, a hold asks.
    case selected(String)
    /// Recording the spoken request about the selection.
    case asking(String)
    /// The request was let go of and is being transcribed.
    case transcribing(String)
    case speaking
  }

  private var mode = Mode.passthrough

  public init() {}

  public mutating func submit(
    _ command: DictationSession.Command, readAloudEnabled: Bool, askEnabled: Bool = false
  ) -> [Action] {
    switch mode {
    case .passthrough:
      guard command == .press, readAloudEnabled else { return [.forward(command)] }
      mode = .deciding(pending: [], asks: askEnabled, latched: false, held: false)
      return askEnabled ? [.readSelection, .startHoldTimer] : [.readSelection]
    case .deciding(var pending, let asks, let latched, let held):
      pending.append(command)
      mode = .deciding(pending: pending, asks: asks, latched: latched, held: held)
      return []
    case .selected:
      // Let go before it was a hold (a hold-only trigger's quick release), or a
      // combo over the selection. Neither asked for anything.
      mode = .passthrough
      return command == .cancelRecording ? [.forward(command)] : []
    case .asking(let selection):
      return asking(selection, command)
    case .transcribing:
      return transcribing(command)
    case .speaking:
      mode = .passthrough
      switch command {
      // A recovery reset still reaches the session, where it can only cancel a
      // live recording, and there isn't one.
      case .cancelRecording: return [.stopSpeech, .forward(command)]
      // A press only arrives here when the gate was idle under the speech: an
      // answer, or a read after a request with nothing said. The press armed
      // the gate, and its key-up would latch a recording nobody started,
      // swallowing the next press. Clear it now instead.
      case .press, .pressHandingBack: return [.stopSpeech, .resetGate]
      case .release, .cancel: return [.stopSpeech]
      }
    }
  }

  private mutating func asking(_ selection: String, _ command: DictationSession.Command) -> [Action] {
    switch command {
    case .release:
      mode = .transcribing(selection)
      return [.forward(.release)]
    case .cancel, .cancelRecording:
      mode = .passthrough
      return [.forward(command)]
    case .press, .pressHandingBack:
      // The key is down for the whole request, so the gate can't press again.
      return []
    }
  }

  private mutating func transcribing(_ command: DictationSession.Command) -> [Action] {
    switch command {
    case .press, .pressHandingBack:
      // A press while the request is transcribing drops it. The gate is armed
      // for this press, and its key-up would latch a recording nobody started.
      mode = .passthrough
      return [.forward(.cancel), .resetGate]
    case .cancel:
      mode = .passthrough
      return [.forward(.cancel)]
    case .release, .cancelRecording:
      // Nothing is recording, so the session treats either as a no-op.
      return [.forward(command)]
    }
  }

  /// The gate latched: the key came up quickly enough to be a tap.
  public mutating func keyLatched() -> [Action] {
    switch mode {
    case .deciding(let pending, let asks, _, let held):
      mode = .deciding(pending: pending, asks: asks, latched: true, held: held)
      return []
    case .selected(let selection):
      mode = .speaking
      return [.speak(selection)]
    case .asking(let selection):
      // Let go before the gate's own hold threshold, so it latched. For a
      // request, letting go is the end of it, and the latch holds no recording
      // the user knows about.
      mode = .transcribing(selection)
      return [.forward(.release), .resetGate]
    case .passthrough, .transcribing, .speaking:
      return []
    }
  }

  /// `askHoldDelay` passed since the press. Meaningful only while the key may
  /// still be down over a selection.
  public mutating func holdElapsed() -> [Action] {
    switch mode {
    case .deciding(let pending, true, let latched, _):
      mode = .deciding(pending: pending, asks: true, latched: latched, held: true)
      return []
    case .selected(let selection):
      mode = .asking(selection)
      return [.forward(.pressHandingBack)]
    case .passthrough, .deciding, .asking, .transcribing, .speaking:
      return []
    }
  }

  public mutating func selectionResolved(_ selection: String?) -> [Action] {
    guard case .deciding(let pending, let asks, let latched, let held) = mode else { return [] }
    guard let selection else {
      mode = .passthrough
      return ([.press] + pending).map(Action.forward)
    }
    // The press was already over before the read returned: a combo cancelled
    // it, or a hold was released. Neither one asked to hear anything. When a
    // later press is among them it still holds the gate, armed or latched, and
    // nothing will run for it, so clear the gate or the next press is swallowed.
    guard pending.isEmpty else {
      mode = .passthrough
      return pending.last == .press ? [.resetGate] : []
    }
    // A tap, or a press that can't ask, reads now.
    if !asks || latched {
      mode = .speaking
      return [.speak(selection)]
    }
    if held {
      mode = .asking(selection)
      return [.forward(.pressHandingBack)]
    }
    mode = .selected(selection)
    return []
  }

  /// The read ended on its own, or failed. The caller must not report a read it
  /// stopped itself: a key stop has already moved on, and a newer read may be
  /// playing.
  public mutating func speechFinished() -> [Action] {
    guard mode == .speaking else { return [] }
    mode = .passthrough
    return [.resetGate]
  }

  /// A dictation reached a terminal phase. While commands are going to the
  /// session, the gate is this router's to sync. While a read or a decision
  /// owns it, an earlier dictation's end must not reset it. A request's end is
  /// the one this router waits for: its transcript (`.handedBack`), nothing
  /// said (`.idle`), or a failure.
  public mutating func sessionReachedTerminalPhase(_ phase: PipelinePhase) -> [Action] {
    switch mode {
    case .passthrough:
      return [.syncGateAfterSession]
    case .asking(let selection), .transcribing(let selection):
      let stillDown = mode == .asking(selection)
      if case .handedBack(let request) = phase {
        mode = .speaking
        // Handed back with the key still down means the session's recording cap
        // released it. Clear the gate, or the eventual key-up would stop the answer.
        return [.answer(request: request, selection: selection)] + (stillDown ? [.resetGate] : [])
      }
      if phase == .idle, !stillDown {
        mode = .speaking
        return [.speak(selection)]
      }
      // The request failed or was cancelled: a dictation ending without a key
      // event, like any other.
      mode = .passthrough
      return [.syncGateAfterSession]
    case .deciding, .selected, .speaking:
      return []
    }
  }
}
