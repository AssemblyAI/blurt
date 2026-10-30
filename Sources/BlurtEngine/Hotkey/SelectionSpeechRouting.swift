/// Decides what each trigger command does, by the action of the key that
/// pressed (`TriggerKeyAction`): a dictating key's commands go straight to the
/// dictation session; a read-aloud key reads the selection aloud; an ask key
/// records a spoken request about the selection and reads the answer. It is a
/// pure state machine. The app's `SelectionSpeechRouter` carries out the
/// actions it returns (the AX read, the hold timer, the speech task, the gate
/// resets), the same split as `DictationKeyRouter` under `DictationKeyTap`.
///
/// **A dictating key never waits on the selection.** Only a read or ask press
/// reads it, so dictation's recording starts at the press as it always has.
///
/// **Read and ask follow their key's tap/hold mode, like dictation**, with one
/// difference: nothing starts at the key-down. A modifier going down over a
/// selection is as often the start of ⌘C as a request to hear it, so the read
/// (or the mic, for an ask) waits for the press to prove itself: a tap (the
/// gate's `.latch`), or the key still down `holdDelay` later in a mode that
/// holds. A combo or a click before then (`.cancel`) did nothing. After that:
/// - A tap's read frees the gate and plays until it ends or any key is
///   pressed: the dictation key then dictates. A hold's plays until the key is
///   let go.
/// - A tapped ask records until the next tap, as a dictation does; a held ask
///   until the key is let go. Then the transcript comes back as `.handedBack`
///   and the answer is read.
///
/// The Accessibility read is in flight while those signals land, so a press
/// first waits in `.deciding`, noting them, and acts once the read returns.
/// With nothing selected the press does nothing.
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
    /// Call `holdElapsed` after `holdDelay`, unless a newer press restarts it.
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

  /// How long a read or ask key must stay down, in a mode that holds, before
  /// the press counts. Well under the gate's 1 s tap/hold threshold, because an
  /// asker waits this long (plus the mic bring-up) for the start chime before
  /// speaking; a deliberate tap is over long before it.
  public static let holdDelay = Duration.milliseconds(350)

  private enum Intent: Sendable, Equatable {
    case read, ask
  }

  /// How a read or ask press proved itself: a tap (the gate latched), or a
  /// hold (still down at `holdDelay`).
  private enum Trigger: Sendable, Equatable {
    case tap, hold
  }

  private enum Mode: Sendable, Equatable {
    case passthrough
    /// The selection read is in flight. `trigger`: how the press already
    /// proved itself, if it has. `ended`: the key let go or a combo cancelled
    /// it; the gate is idle.
    case deciding(Intent, trigger: Trigger?, ended: Bool)
    /// A selection is in hand, and the key is down but hasn't proved itself yet.
    case selected(Intent, String)
    /// Recording the spoken request about the selection. Not `started` while
    /// an earlier dictation is still finishing: the hand-back press waits for
    /// it, since the session refuses a press until it is back at rest.
    /// `byHold`: the key is held for the request, so letting it go — even
    /// before the gate's own hold threshold — ends it; a tapped request runs
    /// until the next tap, like a dictation.
    case asking(String, started: Bool, byHold: Bool)
    /// The request was let go of and is being transcribed (or, not `started`,
    /// was let go of before the mic ever opened).
    case transcribing(String, started: Bool)
    case speaking
  }

  private var mode = Mode.passthrough
  /// Whether the session's last phase was in flight. A terminal phase is then
  /// that dictation's end, never a hand-back press that hasn't started.
  private var sessionBusy = false

  public init() {}

  /// A trigger key went down from idle. `holds`: its mode lets a press be a
  /// hold (anything but tap-only), so a read or ask starts the hold timer.
  public mutating func press(
    key: TriggerKey, action: TriggerKeyAction, holds: Bool
  ) -> [Action] {
    switch mode {
    case .passthrough:
      switch action {
      // Off only reaches here when Settings turned the key off mid-press:
      // dictate, as it was bound to.
      case .dictate, .off: return [.forward(.press(key: key))]
      case .readAloud, .ask:
        mode = .deciding(action == .ask ? .ask : .read, trigger: nil, ended: false)
        return holds ? [.readSelection, .startHoldTimer] : [.readSelection]
      }
    case .speaking:
      // A press only arrives here when the gate was idle under the speech: an
      // answer, or a tapped read, which frees the gate as it starts. Any key
      // stops it. A dictating key then dictates, as pressed; any other key's
      // press armed the gate, and its key-up would latch something nobody
      // started, swallowing the next press, so clear it instead.
      mode = .passthrough
      switch action {
      case .dictate, .off: return [.stopSpeech, .forward(.press(key: key))]
      case .readAloud, .ask: return [.stopSpeech, .resetGate]
      }
    case .transcribing(_, let started):
      // A press while the request is transcribing drops it, for the same reason.
      mode = .passthrough
      return started ? [.forward(.cancel), .resetGate] : [.resetGate]
    case .deciding, .selected, .asking:
      // The gate belongs to the key down now; another press can't start.
      return []
    }
  }

  /// A gate command other than a press: `.release` (the gate's stop),
  /// `.cancel` (a combo), or `.cancelRecording` (a recovery reset).
  public mutating func submit(_ command: DictationSession.Command) -> [Action] {
    switch mode {
    case .passthrough:
      return [.forward(command)]
    case .deciding(let intent, let trigger, _):
      if command == .cancelRecording {
        mode = .passthrough
        return [.forward(command)]
      }
      mode = .deciding(intent, trigger: trigger, ended: true)
      return []
    case .selected:
      // Let go, or a combo, before the press proved itself: nothing asked for.
      mode = .passthrough
      return command == .cancelRecording ? [.forward(command)] : []
    case .asking(let selection, let started, _):
      return asking(selection, started: started, command)
    case .transcribing(_, let started):
      return transcribing(started: started, command)
    case .speaking:
      mode = .passthrough
      // A recovery reset still reaches the session, where it can only cancel a
      // live recording, and there isn't one.
      return command == .cancelRecording ? [.stopSpeech, .forward(command)] : [.stopSpeech]
    }
  }

  private mutating func asking(
    _ selection: String, started: Bool, _ command: DictationSession.Command
  ) -> [Action] {
    switch command {
    case .release:
      mode = .transcribing(selection, started: started)
      return started ? [.forward(.release)] : []
    case .cancel, .cancelRecording:
      mode = .passthrough
      // Unstarted, the session is still busy with the earlier dictation, which
      // a cancel would throw away. A recovery reset still goes through.
      return started || command == .cancelRecording ? [.forward(command)] : []
    case .press, .pressHandingBack:
      return []
    }
  }

  private mutating func transcribing(started: Bool, _ command: DictationSession.Command) -> [Action] {
    switch command {
    case .cancel:
      mode = .passthrough
      return started ? [.forward(.cancel)] : []
    case .release, .cancelRecording:
      // Nothing is recording, so the session treats either as a no-op.
      return [.forward(command)]
    case .press, .pressHandingBack:
      return []
    }
  }

  /// The gate latched: the key came up quickly enough to be a tap (or, in
  /// tap-only mode, came up at all).
  public mutating func keyLatched() -> [Action] {
    switch mode {
    case .deciding(let intent, let trigger, let ended):
      // Held past the delay, then let go before the gate's own threshold: a
      // short hold. A held ask ends there, having asked nothing yet; a read
      // keeps going, as a tapped one does.
      if trigger == .hold, intent == .ask {
        mode = .deciding(intent, trigger: trigger, ended: true)
      } else {
        mode = .deciding(intent, trigger: .tap, ended: ended)
      }
      return []
    case .selected(let intent, let selection):
      return self.trigger(intent, selection, by: .tap)
    case .asking(let selection, let started, byHold: true):
      // Letting go of a held request ends it, before the gate's hold
      // threshold too; the latch holds no recording the user knows about.
      mode = .transcribing(selection, started: started)
      return started ? [.forward(.release), .resetGate] : [.resetGate]
    case .speaking:
      // A held read let go before the gate's threshold keeps playing, latched.
      // Free the gate, as a tapped read does, so the other keys still work.
      return [.resetGate]
    case .passthrough, .asking, .transcribing:
      return []
    }
  }

  /// `holdDelay` passed since the press. Meaningful only while the key may
  /// still be down over a selection.
  public mutating func holdElapsed() -> [Action] {
    switch mode {
    case .deciding(let intent, nil, false):
      mode = .deciding(intent, trigger: .hold, ended: false)
      return []
    case .selected(let intent, let selection):
      return trigger(intent, selection, by: .hold)
    case .passthrough, .deciding, .asking, .transcribing, .speaking:
      return []
    }
  }

  public mutating func selectionResolved(_ selection: String?) -> [Action] {
    guard case .deciding(let intent, let trigger, let ended) = mode else { return [] }
    guard let selection, !ended else {
      mode = .passthrough
      // Nothing selected, or the press already over: nothing to do. A press
      // still holding the gate (down, or latched by a tap) would otherwise
      // swallow the key's next press, so clear it.
      return ended ? [] : [.resetGate]
    }
    if let trigger { return self.trigger(intent, selection, by: trigger) }
    mode = .selected(intent, selection)
    return []
  }

  private mutating func trigger(_ intent: Intent, _ selection: String, by trigger: Trigger) -> [Action] {
    switch intent {
    case .read:
      mode = .speaking
      // A tapped read frees the gate at once: a read can run for many
      // minutes, and the read key holding the gate all that time would leave
      // every other key — dictation's among them — dead until it ended. A
      // held read keeps it, so letting go stops the read.
      return trigger == .tap ? [.speak(selection), .resetGate] : [.speak(selection)]
    case .ask:
      mode = .asking(selection, started: !sessionBusy, byHold: trigger == .hold)
      return sessionBusy ? [] : [.forward(.pressHandingBack(key: nil))]
    }
  }

  /// The read ended on its own, or failed. The caller must not report a read it
  /// stopped itself: a key stop has already moved on, and a newer read may be
  /// playing. The read's key may still hold the gate (latched by a tap), so
  /// clear it, or its next press would only stop a read that's over.
  public mutating func speechFinished() -> [Action] {
    guard mode == .speaking else { return [] }
    mode = .passthrough
    return [.resetGate]
  }

  /// The session's phase changed. Only a terminal phase can need an action:
  /// while commands are going to the session, the gate is this router's to
  /// sync. While a read or a decision owns it, an earlier dictation's end must
  /// not reset it. A request's end is the one this router waits for: its
  /// transcript (`.handedBack`), nothing said (`.idle`), or a failure — and
  /// only once its own press has started; before that, a terminal phase is the
  /// earlier dictation's end, which lets the request start.
  public mutating func sessionPhaseChanged(_ phase: PipelinePhase) -> [Action] {
    sessionBusy = !phase.isTerminal
    guard phase.isTerminal else { return [] }
    switch mode {
    case .passthrough:
      return [.syncGateAfterSession]
    case .asking(let selection, started: false, let byHold):
      mode = .asking(selection, started: true, byHold: byHold)
      return [.forward(.pressHandingBack(key: nil))]
    case .transcribing(_, started: false):
      // Let go before the mic ever opened: nothing was asked.
      mode = .passthrough
      return []
    case .asking(let selection, started: true, _):
      return requestEnded(phase, selection: selection, stillDown: true)
    case .transcribing(let selection, started: true):
      return requestEnded(phase, selection: selection, stillDown: false)
    case .deciding, .selected, .speaking:
      return []
    }
  }

  private mutating func requestEnded(_ phase: PipelinePhase, selection: String, stillDown: Bool) -> [Action] {
    if case .handedBack(let request) = phase {
      mode = .speaking
      // Handed back with the key still down (or latched) means the session's
      // recording cap released it. Clear the gate, or the eventual key-up
      // would stop the answer.
      return [.answer(request: request, selection: selection)] + (stillDown ? [.resetGate] : [])
    }
    // Nothing said, or the request failed or was cancelled: a dictation ending
    // without a key event, like any other.
    mode = .passthrough
    return [.syncGateAfterSession]
  }
}
