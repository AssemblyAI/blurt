import Foundation

// MARK: - The lift half of the table: the stop, the × and their answers

/// What a lift and a × send once a press is out, and how a release or cancel
/// is answered, resent and given up. The press half, and the type, are in
/// `PressHandshake.swift`.
nonisolated extension PressHandshake {
  /// The lift sends nothing: every stop went out on a finger down. A press
  /// that was refused hops on its lift, so the app opens once the finger is
  /// off the key.
  func micUp() -> [Action] {
    if case .unready(let reason) = state { return [.hop(reason)] }
    return [.none]
  }

  func cancelTapped() -> [Action] {
    switch state {
    case .idle, .unready: [.none]
    case .pressing: [.sendCancel(dictation: nil)]
    case .owned(let dictation, _), .foreign(let dictation): [.sendCancel(dictation: dictation)]
    // Over a release already out: the user wants the words gone, and a
    // cancel landing on either side of the release ends it that way.
    case .stopping(_, let dictation, _, _): [.sendCancel(dictation: dictation)]
    }
  }

  mutating func stopSent(id: UUID, at: Date) -> [Action] {
    switch state {
    case .owned(let dictation, _), .foreign(let dictation):
      state = .stopping(id: id, dictation: dictation, sentAt: at, resent: false)
    case .pressing:
      state = .stopping(id: id, dictation: nil, sentAt: at, resent: false)
    case .stopping(_, let dictation, _, _):
      // A × over a release: the newer command is the one awaited.
      state = .stopping(id: id, dictation: dictation, sentAt: at, resent: false)
    case .idle, .unready:
      break
    }
    return [.none]
  }

  /// The stop's own ack ends it. The press's answer landing after a cancel
  /// sent ahead of it gives the dictation a name, for the resend to carry.
  mutating func stopAnswered(by ack: CommandAck) -> [Action] {
    guard case .stopping(let id, let dictation, let sentAt, let resent) = state else { return [.none] }
    if ack.commandID == id { return settle() }
    if dictation == nil, case .started(let named) = ack.outcome {
      state = .stopping(id: id, dictation: named, sentAt: sentAt, resent: resent)
    }
    return [.none]
  }

  /// A terminal phase for the dictation being stopped — or for one with no
  /// name on either side — ends the stop; another dictation's notice does not.
  mutating func stopPhased(_ snapshot: PhaseSnapshot) -> [Action] {
    guard case .stopping(_, let dictation, _, _) = state, snapshot.state.isSettled else { return [.none] }
    let named = snapshot.dictation?.id
    return named == nil || dictation == nil || named == dictation ? settle() : [.none]
  }

  /// One resend at the retry delay; past the deadline the app's watchdog
  /// ends the dictation, and the line for a transcription still running is
  /// `VoiceNotice`'s to show.
  mutating func stopTicked(at now: Date) -> [Action] {
    guard case .stopping(let id, let dictation, let sentAt, let resent) = state else { return [.none] }
    let age = now.timeIntervalSince(sentAt)
    if age >= stopDeadline { return settle() }
    guard !resent, age >= retryDelay else { return [.none] }
    state = .stopping(id: id, dictation: dictation, sentAt: sentAt, resent: true)
    return [.resendStop(id: id)]
  }
}
