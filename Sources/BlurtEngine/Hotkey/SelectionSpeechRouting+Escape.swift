// Escape's routing: a discard of whatever is in flight. Its own file only to
// keep `SelectionSpeechRouting.swift` under the file-length limit.

extension SelectionSpeechRouting {
  /// Whether this router has anything under way: a press deciding or proving
  /// itself, a request recording or transcribing, a read or answer playing, or a
  /// job before it pastes. With the session's own phase, what makes an Escape
  /// worth acting on (`DictationKeyRouter.Event.escapeDown`).
  var isBusy: Bool { mode != .passthrough }

  /// Escape: throw away everything in flight, and paste nothing. Unlike a combo
  /// (`submit(.cancel)`), which a press still deciding absorbs and an earlier
  /// dictation outlives, this stops the router's own work — the read or answer,
  /// the job, the request — *and* cancels the session when it is busy, whichever
  /// of them the user is looking at. The key tap has already cleared the gate.
  ///
  /// In passthrough the cancel goes to the session unconditionally: Escape only
  /// gets here with something in flight, and the session decides by its own
  /// phase (`DictationSession.cancel()` is a no-op at rest), so a host's view of
  /// "in flight" a moment stale can't strand a dictation.
  mutating func escape() -> [Action] {
    let cancelSession: [Action] = sessionBusy ? [.forward(.cancel)] : []
    switch mode {
    case .passthrough:
      return [.forward(.cancel)]
    case .deciding(let intent, _, _):
      // Its selection read is still out: drop the result when it lands.
      mode = .passthrough
      staleReads += 1
      return cancelSession + abandon(intent)
    case .selected(let intent, _):
      mode = .passthrough
      return cancelSession + abandon(intent)
    case .asking(let intent, _, let started, _), .transcribing(let intent, _, let started):
      // Unstarted, the session is busy with an earlier dictation: Escape
      // discards that too.
      mode = .passthrough
      return (started || sessionBusy ? [.forward(.cancel)] : []) + abandon(intent)
    case .speaking:
      mode = .passthrough
      return [.stopSpeech] + cancelSession
    case .working:
      mode = .passthrough
      return [.stopJob] + cancelSession
    }
  }
}
