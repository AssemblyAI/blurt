import Foundation

// MARK: - The lift half of the table: the stop, the × and their answers

/// What a lift and a × send once a press is out, and how a release or cancel
/// is answered, resent and given up. The press half, and the type, are in
/// `PressHandshake.swift`.
nonisolated extension PressHandshake {
  /// A hold's lift is the stop, sent the instant the finger is off the key;
  /// a tap's lift sends nothing (the tap started, the next tap stops). A
  /// press that was refused hops on its lift, so the app opens once the
  /// finger is off the key.
  mutating func micUp(heldFor: TimeInterval) -> [Action] {
    let isHold = heldFor >= holdThreshold
    switch state {
    case .unready(let reason):
      return [.hop(reason)]

    case .idle, .stopping:
      return [.nothing]

    case let .pressing(id, sentAt, resent, _):
      // A hold lifted before the answer: the stop goes out the moment the
      // dictation has an id.
      if isHold { state = .pressing(id: id, sentAt: sentAt, resent: resent, stopWanted: true) }
      return [.nothing]

    case let .owned(dictation, phase):
      // Over the words being made there is nothing to stop.
      if phase == .processing || !isHold {
        return [.nothing]
      }
      return [.sendRelease(dictation: dictation)]

    case .foreign(let dictation):
      return isHold ? [.sendRelease(dictation: dictation)] : [.nothing]
    }
  }

  func cancelTapped() -> [Action] {
    switch state {
    case .idle, .unready:
      [.nothing]

    case .pressing:
      [.sendCancel(dictation: nil)]

    case .owned(let dictation, _), .foreign(let dictation):
      [.sendCancel(dictation: dictation)]

    // Over a release already out: the user wants the words gone, and a
    // cancel landing on either side of the release ends it that way.
    case .stopping(_, let dictation, _, _):
      [.sendCancel(dictation: dictation)]
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
    return [.nothing]
  }

  /// The stop's own ack ends it. The press's answer landing after a cancel
  /// sent ahead of it gives the dictation a name, for the resend to carry.
  mutating func stopAnswered(by ack: CommandAck) -> [Action] {
    guard case let .stopping(id, dictation, sentAt, resent) = state else {
      return [.nothing]
    }
    if ack.commandID == id {
      return settle()
    }
    if dictation == nil, case .started(let named) = ack.outcome {
      state = .stopping(id: id, dictation: named, sentAt: sentAt, resent: resent)
    }
    return [.nothing]
  }

  /// A terminal phase for the dictation being stopped — or for one with no
  /// name on either side — ends the stop; another dictation's notice does not.
  mutating func stopPhased(_ snapshot: PhaseSnapshot) -> [Action] {
    guard case .stopping(_, let dictation, _, _) = state, snapshot.state.isSettled else {
      return [.nothing]
    }
    let named = snapshot.dictation?.id
    return named == nil || dictation == nil || named == dictation ? settle() : [.nothing]
  }

  /// One resend at the retry delay; past the deadline the app's watchdog
  /// ends the dictation, and the line for a transcription still running is
  /// `VoiceNotice`'s to show.
  mutating func stopTicked(at now: Date) -> [Action] {
    guard case let .stopping(id, dictation, sentAt, resent) = state else {
      return [.nothing]
    }
    let age = now.timeIntervalSince(sentAt)
    if age >= stopDeadline {
      return settle()
    }
    guard !resent, age >= retryDelay else {
      return [.nothing]
    }
    state = .stopping(id: id, dictation: dictation, sentAt: sentAt, resent: true)
    return [.resendStop(id: id)]
  }
}
