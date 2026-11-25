import Foundation

// MARK: - The press with a deadline

/// The keyboard's half of a dictation, as a pure state machine. A press goes
/// out and must be answered — by the app's ack record, or by a phase that
/// names the press — before `pressDeadline`, or the keyboard lets it go and
/// the next tap opens the app instead. The answer says whether this keyboard
/// owns a dictation, latched onto one it didn't start, or can't record right
/// now and why. From then on the next finger down is a stop, sent at once
/// with the dictation's id, and so is a hold's lift (`holdThreshold`): tap to
/// start and tap to end, or hold to talk. The stop has a deadline of its own.
///
/// `KeyboardModel` drives it: every finger event, signal and clock tick comes
/// in as an `Event`, every side effect goes out as an `Action` the model
/// performs. Nothing here reads the store, the clock or the gate, so every row
/// is a unit test. `DictationKeyGate` keeps the touches' stamps; the lift
/// brings its own held time.
///
/// The gate is the model's, and the handshake says when a touch is the gate's:
/// `KeyboardModel` calls `gate.modifierDown` only on `armGate`, resets it on
/// `resetGate`, and on `latch` does the synthetic `modifierDown` + `modifierUp`
/// only if `gate.isIdle`; no other action touches it, so it holds exactly the
/// presses that press or stop. The lift half of the table — `micUp`, the ×,
/// the stop and its answers — is in `PressHandshake+Stop.swift`; the states,
/// events and actions are in `PressHandshake+Types.swift`.
package nonisolated struct PressHandshake: Sendable, Equatable {
  /// `KeyboardModel.commandRetryDelay`, as seconds: one resend of an
  /// unanswered command, well inside the deadline.
  package static let defaultRetryDelay: TimeInterval = 0.6
  /// A finger down this long is a hold, and its lift the stop; shorter is a tap.
  package static let defaultHoldThreshold: TimeInterval = 0.35

  package let retryDelay: TimeInterval
  package let pressDeadline: TimeInterval
  package let stopDeadline: TimeInterval
  package let holdThreshold: TimeInterval
  // Set from the rows alone, which `PressHandshake+Stop.swift` also holds.
  package internal(set) var state: State = .idle

  /// The press awaiting an answer.
  package var pressID: UUID? {
    if case .pressing(let id, _, _, _) = state { id } else { nil }
  }

  /// The release or cancel awaiting an answer.
  package var stopID: UUID? {
    if case .stopping(let id, _, _, _) = state { id } else { nil }
  }

  /// The dictation a lift or a × would end.
  package var dictationID: UUID? {
    switch state {
    case .owned(let dictation, _), .foreign(let dictation):
      dictation

    case .stopping(_, let dictation, _, _):
      dictation

    case .idle, .pressing, .unready:
      nil
    }
  }

  package var isIdle: Bool { state == .idle }

  package var isOwned: Bool {
    if case .owned = state { true } else { false }
  }

  /// Why the next lift hops, when it would.
  package var unreadyReason: FailureReason? {
    if case .unready(let reason) = state { reason } else { nil }
  }

  /// Whether a flip — a swipe that began on the orb after its press went out
  /// — can still undo that press: it is unanswered, or the dictation it
  /// started is still connecting. Over a recording the words are kept.
  package var canUndoBeforeRecording: Bool {
    switch state {
    case .pressing:
      true

    case .owned(_, let phase):
      phase == .connecting

    case .idle, .stopping, .foreign, .unready:
      false
    }
  }

  package init(
    retryDelay: TimeInterval = Self.defaultRetryDelay,
    pressDeadline: TimeInterval = BlurtShared.pressDeadline,
    stopDeadline: TimeInterval = BlurtShared.stopDeadline,
    holdThreshold: TimeInterval = Self.defaultHoldThreshold
  ) {
    self.retryDelay = retryDelay
    self.pressDeadline = pressDeadline
    self.stopDeadline = stopDeadline
    self.holdThreshold = holdThreshold
  }

  /// The flip: the ×, but only while `canUndoBeforeRecording`; flipping to
  /// the keys over a recording sends nothing.
  package mutating func undoBeforeRecording(now: Date) -> [Action] {
    guard canUndoBeforeRecording else {
      return [.nothing]
    }
    return handle(.cancelTapped, now: now)
  }

  package mutating func handle(_ event: Event, now: Date) -> [Action] {
    switch event {
    case let .micDown(ready, reason, phase, inFlight):
      return micDown(ready: ready, reason: reason, phase: phase, inFlight: inFlight)

    case .micUp(let heldFor):
      return micUp(heldFor: heldFor)

    case .cancelTapped:
      return cancelTapped()

    case let .pressSent(id, at):
      return pressSent(id: id, at: at)

    case .ack(let ack):
      return answered(by: ack, now: now)

    case .phase(let snapshot):
      return phased(snapshot, now: now)

    case let .stopSent(id, at), let .cancelSent(id, at):
      return stopSent(id: id, at: at)

    case .tick(let at):
      return ticked(at: at)

    case .stateChanged(let record):
      return stateChanged(record, now: now)
    }
  }
}

// MARK: - The press half of the table

nonisolated extension PressHandshake {
  private mutating func micDown(
    ready: Bool, reason: FailureReason?, phase: PhaseSnapshot.State, inFlight: DictationRef?
  ) -> [Action] {
    switch state {
    case .idle, .unready:
      guard ready else {
        state = .unready(reason ?? .sessionOff)
        return [.nothing]
      }
      return pressFromRest(phase: phase, inFlight: inFlight)

    case .owned(let dictation, _), .foreign(let dictation):
      return micDownOverLatch(dictation: dictation, ready: ready, reason: reason, phase: phase, inFlight: inFlight)

    case let .pressing(id, sentAt, resent, _):
      // A second finger down before the answer: the stop goes out the moment
      // the dictation has an id.
      state = .pressing(id: id, sentAt: sentAt, resent: resent, stopWanted: true)
      return [.nothing]

    case .stopping:
      return [.nothing]
    }
  }

  /// The record says a press records now; the phase says whether there is
  /// anything to press: the words still being made, a dictation already
  /// running that this touch latches onto instead, or nothing.
  private mutating func pressFromRest(phase: PhaseSnapshot.State, inFlight: DictationRef?) -> [Action] {
    state = .idle
    switch phase {
    case .processing:
      return [.buzz]

    case .connecting, .recording:
      // A running dictation the app has not named can't be stopped by id.
      guard let inFlight else {
        return [.buzz]
      }
      // A finger down over a dictation visibly running stops it at once.
      state = .foreign(dictation: inFlight.id)
      return [.latch, .sendRelease(dictation: inFlight.id)]

    case .idle, .pasted, .copied, .error:
      return [.armGate, .sendPress, .showConnecting]
    }
  }

  /// A finger down over a latched gate. A dictation still running — ours, or
  /// the one that took its place — is stopped now, unless its words are being
  /// made. A settled phase means it ended unseen: a fresh
  /// press over a cleared gate, if the record still says a press records; a
  /// closed or lapsed window takes none, and the lift hops.
  private mutating func micDownOverLatch(
    dictation: UUID, ready: Bool, reason: FailureReason?, phase: PhaseSnapshot.State, inFlight: DictationRef?
  ) -> [Action] {
    let named = inFlight?.id
    guard phase.isSettled else {
      guard phase != .processing else {
        return [.buzz]
      }
      if let named, named != dictation { state = .foreign(dictation: named) }
      return [.armGate, .sendRelease(dictation: named ?? dictation)]
    }
    // A notice naming another dictation is the previous one's, still up.
    if let named, named != dictation {
      return [.nothing]
    }
    guard ready else {
      return refuse(reason ?? .sessionOff)
    }
    return settle() + pressFromRest(phase: phase, inFlight: nil)
  }

  private mutating func pressSent(id: UUID, at: Date) -> [Action] {
    if state == .idle { state = .pressing(id: id, sentAt: at, resent: false, stopWanted: false) }
    return [.nothing]
  }

  private mutating func answered(by ack: CommandAck, now: Date) -> [Action] {
    switch state {
    case let .pressing(id, sentAt, _, stopWanted):
      guard ack.commandID == id else {
        return [.nothing]
      }
      guard isInTime(sentAt: sentAt, now: now) else {
        return refuse(.unanswered)
      }
      return pressAnswered(ack.outcome, stopWanted: stopWanted)

    case .stopping:
      return stopAnswered(by: ack)

    case .idle, .owned, .foreign, .unready:
      return [.nothing]
    }
  }

  /// The deadline holds whether or not a tick has said so.
  private func isInTime(sentAt: Date, now: Date) -> Bool {
    now.timeIntervalSince(sentAt) < pressDeadline
  }

  private mutating func pressAnswered(_ outcome: CommandAck.Outcome, stopWanted: Bool) -> [Action] {
    switch outcome {
    case .started(let dictation):
      state = .owned(dictation: dictation, phase: .connecting)
      return stopWanted ? [.sendRelease(dictation: dictation)] : [.nothing]

    case .busy(let dictation):
      // The press latched onto it; a second finger down already asked for the stop.
      state = .foreign(dictation: dictation)
      return stopWanted ? [.sendRelease(dictation: dictation)] : [.latch]

    case .notListening(let reason):
      return refuse(reason)

    case .stopped, .cancelled, .notOwner, .nothingInFlight, .stale, .duplicate:
      // Not a press's answer: the router answers a resend with the press's
      // original outcome. The deadline settles a press that gets nothing else.
      return [.nothing]
    }
  }

  private mutating func phased(_ snapshot: PhaseSnapshot, now: Date) -> [Action] {
    switch state {
    case let .pressing(id, sentAt, _, stopWanted):
      // Only a phase that answers our press may settle it: the previous
      // dictation's notice can land a moment after a new press.
      guard snapshot.answers == id else {
        return [.nothing]
      }
      guard isInTime(sentAt: sentAt, now: now) else {
        return refuse(.unanswered)
      }
      return pressAnswered(by: snapshot, stopWanted: stopWanted)

    case .owned(let dictation, _), .foreign(let dictation):
      return follow(snapshot, dictation: dictation)

    case .stopping:
      return stopPhased(snapshot)

    case .idle, .unready:
      return [.nothing]
    }
  }

  /// A lost ack can't time out a dictation the keyboard can see running.
  private mutating func pressAnswered(by snapshot: PhaseSnapshot, stopWanted: Bool) -> [Action] {
    switch snapshot.state {
    case .connecting, .recording, .processing:
      guard let dictation = snapshot.dictation?.id else {
        return [.nothing]
      }
      state = .owned(dictation: dictation, phase: snapshot.state)
      return stopWanted ? [.sendRelease(dictation: dictation)] : [.nothing]

    case .error:
      return refuse(snapshot.reason ?? .unanswered)

    case .idle, .pasted, .copied:
      return settle()
    }
  }

  /// An owned or latched dictation follows the phases that name it, or name
  /// nothing. One naming another is its late notice, ignored, or the next
  /// dictation already running in ours' place, now under the latch.
  private mutating func follow(_ snapshot: PhaseSnapshot, dictation: UUID) -> [Action] {
    if let named = snapshot.dictation?.id, named != dictation {
      if !snapshot.state.isSettled { state = .foreign(dictation: named) }
      return [.nothing]
    }
    guard !snapshot.state.isSettled else {
      return settle()
    }
    if case .owned = state { state = .owned(dictation: dictation, phase: snapshot.state) }
    return [.nothing]
  }

  private mutating func ticked(at now: Date) -> [Action] {
    switch state {
    case let .pressing(id, sentAt, resent, stopWanted):
      let age = now.timeIntervalSince(sentAt)
      if age >= pressDeadline {
        return refuse(.unanswered)
      }
      guard !resent, age >= retryDelay else {
        return [.nothing]
      }
      state = .pressing(id: id, sentAt: sentAt, resent: true, stopWanted: stopWanted)
      return [.resendPress(id: id)]

    case .stopping:
      return stopTicked(at: now)

    case .idle, .owned, .foreign, .unready:
      return [.nothing]
    }
  }

  /// A lapsed lease, or no record, ends trust in the phase: the app is
  /// suspended or dead. A record merely not ready (interrupted, closed) while
  /// our dictation is in flight is an app alive to publish its end itself.
  private mutating func stateChanged(_ record: ListeningState?, now: Date) -> [Action] {
    if let record, record.isReady(now: now) {
      if case .unready = state { state = .idle }
      return [.nothing]
    }
    let lapsed = record.map { $0.leaseUntil <= now } ?? true
    let reason = record?.notReady(now: now) ?? .sessionOff
    switch state {
    case .stopping:
      // A stop already out has its own deadline.
      return [.nothing]

    case .owned:
      return lapsed ? refuse(.suspended) : [.nothing]

    case .pressing, .foreign:
      return refuse(lapsed ? .suspended : reason)

    case .idle, .unready:
      // Said once per reason: the heartbeat feeds the record in every beat.
      let repeated = state == .unready(reason)
      state = .unready(reason)
      return repeated ? [.nothing] : [.show(reason)]
    }
  }

  /// The press is over without a dictation: the gate comes up, the line says
  /// why, and the next lift hops. No haptic — the line is the answer.
  mutating func refuse(_ reason: FailureReason) -> [Action] {
    state = .unready(reason)
    return [.resetGate, .show(reason)]
  }

  /// The dictation is over, however it ended: nothing for the gate to hold.
  mutating func settle() -> [Action] {
    state = .idle
    return [.resetGate]
  }
}
