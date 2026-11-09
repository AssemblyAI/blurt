import Foundation

// MARK: - The press with a deadline

/// The keyboard's half of a dictation, as a pure state machine. A press goes
/// out and must be answered — by the app's ack record, or by a phase that
/// names the press — before `pressDeadline`, or the keyboard lets it go and
/// the next tap opens the app instead. The answer says whether this keyboard
/// owns a dictation, latched onto one it didn't start, or can't record right
/// now and why. From then on a lift is a stop, sent at once with the
/// dictation's id, and the stop has a deadline of its own.
///
/// `KeyboardModel` drives it: every finger event, signal and clock tick comes
/// in as an `Event`, every side effect goes out as an `Action` the model
/// performs. Nothing here reads the store, the clock or the gate, so every row
/// is a unit test. `DictationKeyGate` keeps deciding tap against hold; the
/// handshake agrees with it by being fed the same `holdThreshold` and stamps.
///
/// The gate is the model's, and the handshake says when a touch is the gate's:
/// `KeyboardModel` calls `gate.modifierDown` only on `armGate`, resets it on
/// `resetGate`, and on `latch` does the synthetic `modifierDown` + `modifierUp`
/// only if `gate.isIdle`; no other action touches it, so it holds exactly the
/// presses that press or stop. The lift half of the table — `micUp`, the ×,
/// the stop and its answers — is in `PressHandshake+Stop.swift`.
package nonisolated struct PressHandshake: Sendable, Equatable {
  package nonisolated enum State: Sendable, Equatable {
    case idle
    /// Our press is out and unanswered. `stopWanted`: the finger lifted after
    /// a hold before the answer came. The one command slot holds our press
    /// until the app reads it, so the release waits for the dictation's id
    /// rather than overwriting the press.
    case pressing(id: UUID, sentAt: Date, resent: Bool, stopWanted: Bool)
    /// The app started a dictation for our press; `phase` is the last it
    /// published for it.
    case owned(dictation: UUID, phase: PhaseSnapshot.State)
    /// Our release or cancel is out. `dictation` is nil only for a cancel sent
    /// before the press was answered.
    case stopping(id: UUID, dictation: UUID?, sentAt: Date, resent: Bool)
    /// A dictation another keyboard, or hands-free, started: the gate is
    /// latched over it. `liftStops`: whether the next lift releases it —
    /// false when the app answered our press with `busy` (the tap latched
    /// onto it; its own lift leaves it running, the next tap stops it), true
    /// from a finger down over a dictation visibly running. A hold's lift
    /// releases it either way.
    case foreign(dictation: UUID, liftStops: Bool)
    /// A press would not record; the next lift hops with the reason.
    case unready(FailureReason)
  }

  package nonisolated enum Event: Sendable, Equatable {
    /// Finger down: whether the record says a press records now (and why
    /// not), the phase on screen and the dictation it names.
    case micDown(ready: Bool, reason: FailureReason?, phase: PhaseSnapshot.State, inFlight: DictationRef?)
    /// Finger up: whether the press began from an idle gate, and how long it
    /// was held — the same stamps the gate got.
    case micUp(armedFromIdle: Bool, heldFor: TimeInterval)
    /// The × key, and only that: a flip over the orb is `undoBeforeRecording`.
    case cancelTapped
    /// The model wrote the press; the id and stamp start its deadline.
    case pressSent(id: UUID, at: Date)
    case ack(CommandAck)
    /// A phase the app published. Its `answers` and `dictation` are what matter here.
    case phase(PhaseSnapshot)
    case stopSent(id: UUID, at: Date)
    case cancelSent(id: UUID, at: Date)
    /// The clock, on the same scale as the stamps above.
    case tick(now: Date)
    /// The app's readiness record changed, or is gone. `KeyboardModel` also
    /// feeds the current record in on its 4 s heartbeat
    /// (`SharedStore.keyboardHeartbeatInterval`), so a dead app is noticed.
    case stateChanged(ListeningState?)
  }

  package nonisolated enum Action: Sendable, Equatable {
    /// This touch is the gate's: `KeyboardModel` calls `gate.modifierDown` on
    /// this and nothing else. A press from rest, or a finger down over a
    /// latched dictation the lift may stop; never unready, a buzz, or a press
    /// or stop still out.
    case armGate
    case sendPress
    /// The same press again, same id: a Darwin notification can be missed.
    case resendPress(id: UUID)
    /// The same release or cancel again, same id.
    case resendStop(id: UUID)
    /// `gate.reset()`: nothing for the gate to hold.
    case resetGate
    /// A release; nil when the dictation has no name yet.
    case sendRelease(dictation: UUID?)
    case sendCancel(dictation: UUID?)
    /// Latch the gate over a dictation this keyboard didn't start, so the lift
    /// stops it: the synthetic `modifierDown` + `modifierUp`, only if
    /// `gate.isIdle` — the finger may be down, or a tap may have latched it.
    case latch
    case showConnecting
    case show(FailureReason)
    case hop(FailureReason?)
    /// The warning haptic: the words are still being made, nothing to press.
    case buzz
    case none
  }

  /// `KeyboardModel.commandRetryDelay`, as seconds: one resend of an
  /// unanswered command, well inside the deadline.
  package static let defaultRetryDelay: TimeInterval = 0.6
  /// `DictationKeyGate`'s default: a lift at or past this is a hold.
  package static let defaultHoldThreshold: TimeInterval = 1

  package let retryDelay: TimeInterval
  package let pressDeadline: TimeInterval
  package let stopDeadline: TimeInterval
  package let holdThreshold: TimeInterval
  // Set from the rows alone, which `PressHandshake+Stop.swift` also holds.
  package internal(set) var state: State = .idle

  package init(
    retryDelay: TimeInterval = PressHandshake.defaultRetryDelay,
    pressDeadline: TimeInterval = BlurtShared.pressDeadline,
    stopDeadline: TimeInterval = BlurtShared.stopDeadline,
    holdThreshold: TimeInterval = PressHandshake.defaultHoldThreshold
  ) {
    self.retryDelay = retryDelay
    self.pressDeadline = pressDeadline
    self.stopDeadline = stopDeadline
    self.holdThreshold = holdThreshold
  }

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
    case .owned(let dictation, _), .foreign(let dictation, _): dictation
    case .stopping(_, let dictation, _, _): dictation
    case .idle, .pressing, .unready: nil
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
    case .pressing: true
    case .owned(_, let phase): phase == .connecting
    case .idle, .stopping, .foreign, .unready: false
    }
  }

  /// The flip: the ×, but only while `canUndoBeforeRecording`; flipping to
  /// the keys over a recording sends nothing.
  package mutating func undoBeforeRecording(now: Date) -> [Action] {
    guard canUndoBeforeRecording else { return [.none] }
    return handle(.cancelTapped, now: now)
  }

  package mutating func handle(_ event: Event, now: Date) -> [Action] {
    switch event {
    case .micDown(let ready, let reason, let phase, let inFlight):
      return micDown(ready: ready, reason: reason, phase: phase, inFlight: inFlight)
    case .micUp(let armedFromIdle, let heldFor):
      return micUp(armedFromIdle: armedFromIdle, heldFor: heldFor)
    case .cancelTapped:
      return cancelTapped()
    case .pressSent(let id, let at):
      return pressSent(id: id, at: at)
    case .ack(let ack):
      return answered(by: ack, now: now)
    case .phase(let snapshot):
      return phased(snapshot, now: now)
    case .stopSent(let id, let at), .cancelSent(let id, let at):
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
        return [.none]
      }
      return pressFromRest(phase: phase, inFlight: inFlight)
    case .owned(let dictation, _), .foreign(let dictation, _):
      return micDownOverLatch(dictation: dictation, ready: ready, reason: reason, phase: phase, inFlight: inFlight)
    case .pressing, .stopping:
      return [.none]
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
      guard let inFlight else { return [.buzz] }
      state = .foreign(dictation: inFlight.id, liftStops: true)
      return [.latch]
    case .idle, .pasted, .copied, .error:
      return [.armGate, .sendPress, .showConnecting]
    }
  }

  /// A finger down over a latched gate. A dictation still running — ours, or
  /// the one that took its place — is the gate's to stop on the lift, unless
  /// its words are being made. A settled phase means it ended unseen: a fresh
  /// press over a cleared gate, if the record still says a press records; a
  /// closed or lapsed window takes none, and the lift hops.
  private mutating func micDownOverLatch(
    dictation: UUID, ready: Bool, reason: FailureReason?, phase: PhaseSnapshot.State, inFlight: DictationRef?
  ) -> [Action] {
    let named = inFlight?.id
    guard phase.isSettled else {
      let stoppable = phase != .processing
      if let named, named != dictation {
        state = .foreign(dictation: named, liftStops: stoppable)
      } else if case .foreign(let latched, _) = state {
        state = .foreign(dictation: latched, liftStops: stoppable)
      }
      return stoppable ? [.armGate] : [.buzz]
    }
    // A notice naming another dictation is the previous one's, still up.
    if let named, named != dictation { return [.none] }
    guard ready else { return refuse(reason ?? .sessionOff) }
    return settle() + pressFromRest(phase: phase, inFlight: nil)
  }

  private mutating func pressSent(id: UUID, at: Date) -> [Action] {
    if state == .idle { state = .pressing(id: id, sentAt: at, resent: false, stopWanted: false) }
    return [.none]
  }

  private mutating func answered(by ack: CommandAck, now: Date) -> [Action] {
    switch state {
    case .pressing(let id, let sentAt, _, let stopWanted):
      guard ack.commandID == id else { return [.none] }
      guard isInTime(sentAt: sentAt, now: now) else { return refuse(.unanswered) }
      return pressAnswered(ack.outcome, stopWanted: stopWanted)
    case .stopping:
      return stopAnswered(by: ack)
    case .idle, .owned, .foreign, .unready:
      return [.none]
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
      return stopWanted ? [.sendRelease(dictation: dictation)] : [.none]
    case .busy(let dictation):
      // The tap latched onto it; a hold's lift already asked for the stop.
      state = .foreign(dictation: dictation, liftStops: false)
      return stopWanted ? [.sendRelease(dictation: dictation)] : [.latch]
    case .notListening(let reason):
      return refuse(reason)
    case .stopped, .cancelled, .notOwner, .nothingInFlight, .stale, .duplicate:
      // Not a press's answer: the router answers a resend with the press's
      // original outcome. The deadline settles a press that gets nothing else.
      return [.none]
    }
  }

  private mutating func phased(_ snapshot: PhaseSnapshot, now: Date) -> [Action] {
    switch state {
    case .pressing(let id, let sentAt, _, let stopWanted):
      // Only a phase that answers our press may settle it: the previous
      // dictation's notice can land a moment after a new press.
      guard snapshot.answers == id else { return [.none] }
      guard isInTime(sentAt: sentAt, now: now) else { return refuse(.unanswered) }
      return pressAnswered(by: snapshot, stopWanted: stopWanted)
    case .owned(let dictation, _), .foreign(let dictation, _):
      return follow(snapshot, dictation: dictation)
    case .stopping:
      return stopPhased(snapshot)
    case .idle, .unready:
      return [.none]
    }
  }

  /// A lost ack can't time out a dictation the keyboard can see running.
  private mutating func pressAnswered(by snapshot: PhaseSnapshot, stopWanted: Bool) -> [Action] {
    switch snapshot.state {
    case .connecting, .recording, .processing:
      guard let dictation = snapshot.dictation?.id else { return [.none] }
      state = .owned(dictation: dictation, phase: snapshot.state)
      return stopWanted ? [.sendRelease(dictation: dictation)] : [.none]
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
      if !snapshot.state.isSettled { state = .foreign(dictation: named, liftStops: true) }
      return [.none]
    }
    guard !snapshot.state.isSettled else { return settle() }
    if case .owned = state { state = .owned(dictation: dictation, phase: snapshot.state) }
    return [.none]
  }

  private mutating func ticked(at now: Date) -> [Action] {
    switch state {
    case .pressing(let id, let sentAt, let resent, let stopWanted):
      let age = now.timeIntervalSince(sentAt)
      if age >= pressDeadline { return refuse(.unanswered) }
      guard !resent, age >= retryDelay else { return [.none] }
      state = .pressing(id: id, sentAt: sentAt, resent: true, stopWanted: stopWanted)
      return [.resendPress(id: id)]
    case .stopping:
      return stopTicked(at: now)
    case .idle, .owned, .foreign, .unready:
      return [.none]
    }
  }

  /// A lapsed lease, or no record, ends trust in the phase: the app is
  /// suspended or dead. A record merely not ready (interrupted, closed) while
  /// our dictation is in flight is an app alive to publish its end itself.
  private mutating func stateChanged(_ record: ListeningState?, now: Date) -> [Action] {
    if let record, record.isReady(now: now) {
      if case .unready = state { state = .idle }
      return [.none]
    }
    let lapsed = record.map { $0.leaseUntil <= now } ?? true
    let reason = record?.notReady(now: now) ?? .sessionOff
    switch state {
    case .stopping:
      // A stop already out has its own deadline.
      return [.none]
    case .owned:
      return lapsed ? refuse(.suspended) : [.none]
    case .pressing, .foreign:
      return refuse(lapsed ? .suspended : reason)
    case .idle, .unready:
      // Said once per reason: the heartbeat feeds the record in every beat.
      let repeated = state == .unready(reason)
      state = .unready(reason)
      return repeated ? [.none] : [.show(reason)]
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
