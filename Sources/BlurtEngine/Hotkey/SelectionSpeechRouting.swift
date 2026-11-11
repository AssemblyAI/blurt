/// Decides what each trigger command does, by the action of the key that
/// pressed (`TriggerKeyAction`): a dictating key's commands go straight to the
/// dictation session; a read-aloud key reads the selection aloud; an ask key
/// records a spoken request about the selection and reads the answer; a rewrite
/// key records a spoken instruction and pastes the selection, rewritten, over
/// it; a compose key records spoken instructions and pastes what they
/// describe at the cursor; a command key records a spoken command and
/// carries it out. It is a
/// pure state machine. The app's `SelectionSpeechRouter` carries out the
/// actions it returns (the AX read, the hold timer, the speech task, the gate
/// resets), the same split as `DictationKeyRouter` under `DictationKeyTap`.
///
/// **A dictating key never waits on the selection.** Only a read or ask press
/// reads it, so dictation's recording starts at the press as it always has.
///
/// **Read, ask and rewrite follow their key's tap/hold mode, like dictation**, with one
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
///   and the answer is read. A rewrite records the same way, and its
///   transcript is the instruction the selection is rewritten by.
/// - A command records the same way, and its transcript is carried out. It
///   needs no selection, so it skips the read: the press is `.selected` from
///   the key-down, and still waits to prove itself before the mic opens. A
///   compose press does the same, and its transcript is the instructions for
///   what to write.
///
/// The Accessibility read is in flight while those signals land, so a press
/// first waits in `.deciding`, noting them, and acts once the read returns.
/// With nothing selected the press does nothing.
///
/// **This owns every "the gate is stale" decision.** A dictation that ends
/// without a key event leaves the gate latched, and so does a read that ends on
/// its own, or a held ask let go before its read returns. Each asks for a
/// different reset: `.syncGateAfterSession` goes through the tap's recovery path,
/// for a dictation, while `.resetGate` just clears it, because no recording is
/// involved.
struct SelectionSpeechRouting: Sendable {
  /// How long a read or ask key must stay down, in a mode that holds, before
  /// the press counts. Well under the gate's 1 s tap/hold threshold, because an
  /// asker waits this long (plus the mic bring-up) for the start chime before
  /// speaking; a deliberate tap is over long before it.
  static let holdDelay = Duration.milliseconds(350)

  private var mode = Mode.passthrough
  /// Whether the session's last phase was in flight. A terminal phase is then
  /// that dictation's end, never a hand-back press that hasn't started.
  private var sessionBusy = false
  /// Reads still in flight for presses a newer press already replaced. Their
  /// results are dropped as they land, before any newer read's.
  private var staleReads = 0

  init() {}

  /// Whether a press of this router's is under way — its selection read, its
  /// recording, its transcription, its read or answer, its job. False only at
  /// rest (`.passthrough`), where a dictating key's presses go straight through.
  var isHandlingPress: Bool { mode != .passthrough }

  /// Whether the press recording now is a command's. The music pause leaves a
  /// command's recording alone (`MediaPauseGate`).
  var recordsCommand: Bool {
    if case .asking(.command, _, _, _) = mode { true } else { false }
  }

  /// What the pill shows while the session records or transcribes a job's
  /// spoken words, in place of "Transcribing": "Rewriting" for a rewrite's
  /// instruction, "Writing" for a composition's, "Working" for a command.
  /// Nil for anything else.
  var processingState: OverlayUIState? {
    switch mode {
    case .asking(let intent, _, _, _), .transcribing(let intent, _, _):
      switch intent {
      case .rewrite: .rewriting
      case .compose: .composing
      case .command: .commanding
      case .read, .ask: nil
      }
    default: nil
    }
  }

  /// A trigger key went down from idle. `holds`: its mode lets a press be a
  /// hold (anything but tap-only), so a read or ask starts the hold timer.
  mutating func press(
    key: TriggerKey, action: TriggerKeyAction, holds: Bool
  ) -> [Action] {
    switch mode {
    case .passthrough:
      switch action {
      // Off only reaches here when Settings turned the key off mid-press:
      // dictate, as it was bound to.
      case .dictate, .off: return [.forward(.press(key: key))]
      case .command, .compose:
        // Nothing to read: the press only has to prove itself.
        mode = .selected(Self.intent(action), "")
        return holds ? [.startHoldTimer] : []
      case .readAloud, .ask, .rewrite:
        mode = .deciding(Self.intent(action), trigger: nil, ended: false)
        return holds ? [.readSelection, .startHoldTimer] : [.readSelection]
      }
    case .speaking:
      // A press only arrives here when the gate was idle under the speech: an
      // answer, or a tapped read, which frees the gate as it starts.
      return interrupt(with: .stopSpeech, key: key, action: action)
    case .working:
      // Any press abandons a rewrite or a composition before it pastes, or a
      // command before its next step, as it stops a read:
      // a paste landing in the middle of whatever the press starts would be
      // the worse surprise. The gate is free here too.
      return interrupt(with: .stopJob, key: key, action: action)
    case .transcribing(let intent, _, let started):
      // A press while the request is transcribing drops it, for the same reason.
      mode = .passthrough
      return (started ? [.forward(.cancel), .resetGate] : [.resetGate]) + abandon(intent)
    case .deciding(_, trigger: _, ended: true):
      // The press is over and the gate idle, only its read still out: this is a
      // fresh press, not one riding the old. Swallowing it would leave the gate
      // armed by a press nothing started, and its key-up latched for good. Take
      // it as from passthrough, and drop the old read's result when it lands, so
      // it can't decide this press.
      mode = .passthrough
      staleReads += 1
      return press(key: key, action: action, holds: holds)
    case .deciding, .selected, .asking:
      // The gate belongs to the key down now; another press can't start.
      return []
    }
  }

  /// A press over a read, answer or rewrite running with the gate free: any
  /// key stops it (`stop`). A dictating key then dictates, as pressed; any
  /// other key's press armed the gate, and its key-up would latch something
  /// nobody started, swallowing the next press, so clear it instead.
  private mutating func interrupt(with stop: Action, key: TriggerKey, action: TriggerKeyAction) -> [Action] {
    mode = .passthrough
    switch action {
    case .dictate, .off: return [stop, .forward(.press(key: key))]
    case .readAloud, .ask, .rewrite, .compose, .command: return [stop, .resetGate]
    }
  }

  /// A gate command other than a press: `.release` (the gate's stop),
  /// `.cancel` (a combo), or `.cancelRecording` (a recovery reset).
  mutating func submit(_ command: DictationSession.Command) -> [Action] {
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
    case .asking(let intent, let selection, let started, _):
      return asking(intent, selection, started: started, command)
    case .transcribing(let intent, _, let started):
      return transcribing(intent, started: started, command)
    case .speaking, .working:
      let stop: Action = mode == .speaking ? .stopSpeech : .stopJob
      mode = .passthrough
      // A recovery reset still reaches the session, where it can only cancel a
      // live recording, and there isn't one.
      return command == .cancelRecording ? [stop, .forward(command)] : [stop]
    }
  }

  private mutating func asking(
    _ intent: Intent, _ selection: String, started: Bool, _ command: DictationSession.Command
  ) -> [Action] {
    switch command {
    case .release:
      return (started ? [.forward(.release)] : []) + beginTranscribing(intent, selection, started: started)
    case .cancel, .cancelRecording:
      mode = .passthrough
      // Unstarted, the session is still busy with the earlier dictation, which
      // a cancel would throw away. A recovery reset still goes through.
      return (started || command == .cancelRecording ? [.forward(command)] : []) + abandon(intent)
    case .press, .pressHandingBack:
      return []
    }
  }

  /// The request's recording ends and its transcription starts. A command's
  /// screen is read now (`.readScreen`), while it transcribes: the screen as
  /// it was when the user stopped speaking is what the command refers to,
  /// and the read's time overlaps the transcription's rather than adding to it.
  private mutating func beginTranscribing(_ intent: Intent, _ selection: String, started: Bool) -> [Action] {
    mode = .transcribing(intent, selection, started: started)
    return started && intent == .command ? [.readScreen] : []
  }

  private mutating func transcribing(
    _ intent: Intent, started: Bool, _ command: DictationSession.Command
  ) -> [Action] {
    switch command {
    case .cancel:
      mode = .passthrough
      return (started ? [.forward(.cancel)] : []) + abandon(intent)
    case .release, .cancelRecording:
      // Nothing is recording, so the session treats either as a no-op.
      return [.forward(command)]
    case .press, .pressHandingBack:
      return []
    }
  }

  /// The gate latched: the key came up quickly enough to be a tap (or, in
  /// tap-only mode, came up at all).
  mutating func keyLatched() -> [Action] {
    switch mode {
    case .deciding(let intent, let trigger, let ended):
      // Held past the delay, then let go before the gate's own threshold: a
      // short hold. A held ask (or rewrite) ends there, having asked nothing yet, so free the
      // gate this latch left behind: nothing later will, since `selectionResolved`
      // then finds the press ended and no session started to reach a terminal
      // phase. A read keeps going, as a tapped one does.
      if trigger == .hold, intent.records {
        mode = .deciding(intent, trigger: trigger, ended: true)
        return [.resetGate]
      }
      mode = .deciding(intent, trigger: .tap, ended: ended)
      return []
    case .selected(let intent, let selection):
      return self.trigger(intent, selection, by: .tap)
    case .asking(let intent, let selection, let started, byHold: true):
      // Letting go of a held request ends it, before the gate's hold
      // threshold too; the latch holds no recording the user knows about.
      return (started ? [.forward(.release), .resetGate] : [.resetGate])
        + beginTranscribing(intent, selection, started: started)
    case .speaking:
      // A held read let go before the gate's threshold keeps playing, latched.
      // Free the gate, as a tapped read does, so the other keys still work.
      return [.resetGate]
    case .passthrough, .asking, .transcribing, .working:
      return []
    }
  }

  /// `holdDelay` passed since the press. Meaningful only while the key may
  /// still be down over a selection.
  mutating func holdElapsed() -> [Action] {
    switch mode {
    case .deciding(let intent, nil, false):
      mode = .deciding(intent, trigger: .hold, ended: false)
      return []
    case .selected(let intent, let selection):
      return trigger(intent, selection, by: .hold)
    case .passthrough, .deciding, .asking, .transcribing, .speaking, .working:
      return []
    }
  }

  mutating func selectionResolved(_ selection: String?) -> [Action] {
    // Reads resolve in the order they started, near enough: a replaced press's
    // read is the older, so it lands first. Out of order, the newer press is
    // decided by the older read of the same selection instead.
    if staleReads > 0 {
      staleReads -= 1
      return []
    }
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
    case .ask, .rewrite, .compose, .command:
      mode = .asking(intent, selection, started: !sessionBusy, byHold: trigger == .hold)
      // A command's screen is prepared now (`.prepareCommand`), while it's
      // spoken — and before the session is free to record it, if it isn't yet.
      let prepare: [Action] = intent == .command ? [.prepareCommand] : []
      return prepare + (sessionBusy ? [] : [.forward(.pressHandingBack(key: nil))])
    }
  }

  /// The read ended on its own, or failed. The caller must not report a read it
  /// stopped itself: a key stop has already moved on, and a newer read may be
  /// playing. The read's key may still hold the gate (latched by a tap), so
  /// clear it, or its next press would only stop a read that's over.
  mutating func speechFinished() -> [Action] {
    guard mode == .speaking else { return [] }
    mode = .passthrough
    return [.resetGate]
  }

  /// The job — a rewrite, a composition or a command — finished or failed. As with
  /// `speechFinished`, the caller must not report a job it stopped itself.
  mutating func jobFinished() -> [Action] {
    guard mode == .working else { return [] }
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
  mutating func sessionPhaseChanged(_ phase: PipelinePhase) -> [Action] {
    sessionBusy = !phase.isTerminal
    guard phase.isTerminal else { return [] }
    switch mode {
    case .passthrough:
      return [.syncGateAfterSession]
    case .asking(let intent, let selection, started: false, let byHold):
      mode = .asking(intent, selection, started: true, byHold: byHold)
      return [.forward(.pressHandingBack(key: nil))]
    case .transcribing(_, _, started: false):
      // Let go before the mic ever opened: nothing was asked.
      mode = .passthrough
      return []
    case .asking(let intent, let selection, started: true, _):
      return requestEnded(phase, intent: intent, selection: selection, stillDown: true)
    case .transcribing(let intent, let selection, started: true):
      return requestEnded(phase, intent: intent, selection: selection, stillDown: false)
    case .deciding, .selected, .speaking, .working:
      return []
    }
  }

  private mutating func requestEnded(
    _ phase: PipelinePhase, intent: Intent, selection: String, stillDown: Bool
  ) -> [Action] {
    if case .handedBack(let request) = phase {
      // Handed back with the key still down (or latched) means the session's
      // recording cap released it. Clear the gate, or the eventual key-up
      // would stop the answer (or abandon the rewrite).
      let reset: [Action] = stillDown ? [.resetGate] : []
      switch intent {
      case .rewrite:
        mode = .working
        return [.rewrite(request: request, selection: selection)] + reset
      case .compose:
        mode = .working
        return [.compose(request: request)] + reset
      case .command:
        mode = .working
        // Handed back by the recording cap, the key still down, it skipped
        // `beginTranscribing`: read the screen now.
        return (stillDown ? [.readScreen] : []) + [.runCommand(request)] + reset
      case .ask, .read:
        mode = .speaking
        return [.answer(request: request, selection: selection)] + reset
      }
    }
    // Nothing said, or the request failed or was cancelled: a dictation ending
    // without a key event, like any other.
    mode = .passthrough
    return [.syncGateAfterSession] + abandon(intent)
  }

  /// A command dropped before it ran — nothing said, a combo, a press while
  /// it transcribed — still has its screen read under way and, in a Chromium
  /// browser, its page tree switched on: `.stopJob` stops one and undoes the
  /// other. Nothing for any other request.
  private func abandon(_ intent: Intent) -> [Action] {
    intent == .command ? [.stopJob] : []
  }
}
