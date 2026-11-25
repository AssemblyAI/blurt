// How a press's work ends: a read or job finishing, the session's phase
// arriving at rest, and Escape. Apart from the presses that start the work
// (`SelectionSpeechRouting.swift`) only to keep that file readable.
extension SelectionSpeechRouting {
  /// The read ended on its own, or failed. The caller must not report a read it
  /// stopped itself: a key stop has already moved on, and a newer read may be
  /// playing. The read's key may still hold the gate (latched by a tap), so
  /// clear it, or its next press would only stop a read that's over.
  mutating func speechFinished() -> [Action] {
    guard mode == .speaking else {
      return []
    }
    mode = .passthrough
    return [.resetGate]
  }

  /// The job — a rewrite, a composition or a command — finished or failed. As with
  /// `speechFinished`, the caller must not report a job it stopped itself.
  mutating func jobFinished() -> [Action] {
    guard mode == .working else {
      return []
    }
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
    guard phase.isTerminal else {
      return []
    }
    switch mode {
    case .passthrough:
      return [.syncGateAfterSession]

    case let .asking(intent, selection, started: false, byHold):
      mode = .asking(intent, selection, started: true, byHold: byHold)
      return [.forward(.pressHandingBack(key: nil))]

    case .transcribing(_, _, started: false):
      // Let go before the mic ever opened: nothing was asked.
      mode = .passthrough
      return []

    case let .asking(intent, selection, started: true, _):
      return requestEnded(phase, intent: intent, selection: selection, stillDown: true)

    case let .transcribing(intent, selection, started: true):
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
    return [.syncGateAfterSession] + intent.abandoned
  }

  /// Escape: throw away everything in flight, and paste nothing. Unlike a combo
  /// (`submit(.cancel)`), it stops the router's own work *and* cancels a busy
  /// session. In passthrough the cancel goes to the session unconditionally — its
  /// `cancel()` is a no-op at rest — so a moment-stale "busy" can't strand a dictation.
  mutating func escape() -> [Action] {
    let busy: [Action] = sessionBusy ? [.forward(.cancel)] : []
    defer { mode = .passthrough }
    switch mode {
    case .passthrough:
      return [.forward(.cancel)]

    case .deciding:
      staleReads += 1  // its selection read is still out
      return busy

    case .selected:
      return busy  // nothing prepared yet, as with a combo (`submit`)

    case let .asking(intent, _, started, _), let .transcribing(intent, _, started):
      // Unstarted, the session is busy with an earlier dictation: discard it too.
      return (started || sessionBusy ? [.forward(.cancel)] : []) + intent.abandoned

    case .speaking:
      return [.stopSpeech] + busy

    case .working:
      return [.stopJob] + busy
    }
  }
}
