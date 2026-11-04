import BlurtEngine
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
    /// latched over it so one lift stops it.
    case foreign(dictation: UUID)
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
    /// The × key, or a flip recognised before recording.
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
    /// The app's readiness record changed, or is gone.
    case stateChanged(ListeningState?)
  }

  package nonisolated enum Action: Sendable, Equatable {
    case sendPress
    /// The same press again, same id: a Darwin notification can be missed.
    case resendPress(id: UUID)
    /// The same release or cancel again, same id.
    case resendStop(id: UUID)
    case resetGate
    /// A release; nil when the dictation has no name yet.
    case sendRelease(dictation: UUID?)
    case sendCancel(dictation: UUID?)
    /// Latch the gate, if idle, over a dictation this keyboard didn't start, so
    /// the lift stops it. Never over an armed or latched gate: the finger may
    /// still be down, or a tap may already have latched it.
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
  package private(set) var state: State = .idle

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
    case .owned(let dictation, _), .foreign(let dictation): dictation
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
      return answered(by: ack)
    case .phase(let snapshot):
      return phased(snapshot)
    case .stopSent(let id, let at), .cancelSent(let id, let at):
      return stopSent(id: id, at: at)
    case .tick(let at):
      return ticked(at: at)
    case .stateChanged(let record):
      return stateChanged(record, now: now)
    }
  }
}

// MARK: - The rows

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
    case .owned(let dictation, _), .foreign(let dictation):
      return micDownOverLatch(dictation: dictation, phase: phase, inFlight: inFlight)
    case .pressing, .stopping:
      return [.none]
    }
  }

  /// The record says a press records now. The phase says whether there is
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
      state = .foreign(dictation: inFlight.id)
      return [.latch]
    case .idle, .pasted, .copied, .error:
      return [.sendPress, .showConnecting]
    }
  }

  /// A finger down over a latched gate: the lift is the stop, unless the
  /// phase shows the dictation ended unseen, in which case this touch
  /// begins a fresh press over a cleared gate.
  private mutating func micDownOverLatch(
    dictation: UUID, phase: PhaseSnapshot.State, inFlight: DictationRef?
  ) -> [Action] {
    let named = inFlight?.id
    guard phase.isSettled else {
      // Ours gave way to another dictation: the latch now covers that one.
      if let named, named != dictation { state = .foreign(dictation: named) }
      return [.none]
    }
    // A notice naming another dictation is the previous one's, still up.
    if let named, named != dictation { return [.none] }
    return settle() + pressFromRest(phase: phase, inFlight: nil)
  }

  private mutating func micUp(armedFromIdle: Bool, heldFor: TimeInterval) -> [Action] {
    let isTap = armedFromIdle && heldFor < holdThreshold
    switch state {
    case .unready(let reason):
      return [.hop(reason)]
    case .idle, .stopping:
      return [.none]
    case .pressing(let id, let sentAt, let resent, _):
      // A tap latched the gate and the answer decides what it holds. A hold's
      // lift is a stop, sent the moment the dictation has an id.
      if !isTap { state = .pressing(id: id, sentAt: sentAt, resent: resent, stopWanted: true) }
      return [.none]
    case .owned(let dictation, _):
      return isTap ? [.none] : [.sendRelease(dictation: dictation)]
    case .foreign(let dictation):
      return [.sendRelease(dictation: dictation)]
    }
  }

  private func cancelTapped() -> [Action] {
    switch state {
    case .idle, .unready: [.none]
    case .pressing: [.sendCancel(dictation: nil)]
    case .owned(let dictation, _), .foreign(let dictation): [.sendCancel(dictation: dictation)]
    // Over a release already out: the user wants the words gone, and a
    // cancel landing on either side of the release ends it that way.
    case .stopping(_, let dictation, _, _): [.sendCancel(dictation: dictation)]
    }
  }

  private mutating func pressSent(id: UUID, at: Date) -> [Action] {
    if state == .idle { state = .pressing(id: id, sentAt: at, resent: false, stopWanted: false) }
    return [.none]
  }

  private mutating func stopSent(id: UUID, at: Date) -> [Action] {
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

  private mutating func answered(by ack: CommandAck) -> [Action] {
    switch state {
    case .pressing(let id, _, _, let stopWanted):
      guard ack.commandID == id else { return [.none] }
      return pressAnswered(ack.outcome, stopWanted: stopWanted)
    case .stopping(let id, let dictation, let sentAt, let resent):
      if ack.commandID == id { return settle() }
      // The press's own answer, landing after a cancel sent ahead of it:
      // the dictation has a name now, for the resend to carry.
      if dictation == nil, case .started(let named) = ack.outcome {
        state = .stopping(id: id, dictation: named, sentAt: sentAt, resent: resent)
      }
      return [.none]
    case .idle, .owned, .foreign, .unready:
      return [.none]
    }
  }

  private mutating func pressAnswered(_ outcome: CommandAck.Outcome, stopWanted: Bool) -> [Action] {
    switch outcome {
    case .started(let dictation):
      state = .owned(dictation: dictation, phase: .connecting)
      return stopWanted ? [.sendRelease(dictation: dictation)] : [.none]
    case .busy(let dictation):
      state = .foreign(dictation: dictation)
      return stopWanted ? [.sendRelease(dictation: dictation)] : [.latch]
    case .notListening(let reason):
      return refuse(reason)
    case .stopped, .cancelled, .notOwner, .nothingInFlight, .stale, .duplicate:
      // Dropped as too old, answered before we asked again, or not a press's
      // answer at all: nothing started for it.
      return refuse(.unanswered)
    }
  }

  private mutating func phased(_ snapshot: PhaseSnapshot) -> [Action] {
    switch state {
    case .pressing(let id, _, _, let stopWanted):
      // Only a phase that answers our press may settle it: the previous
      // dictation's notice can land a moment after a new press.
      guard snapshot.answers == id else { return [.none] }
      return pressAnswered(by: snapshot, stopWanted: stopWanted)
    case .owned(let dictation, _), .foreign(let dictation):
      return follow(snapshot, dictation: dictation)
    case .stopping(_, let dictation, _, _):
      guard snapshot.state.isSettled else { return [.none] }
      let named = snapshot.dictation?.id
      return named == nil || dictation == nil || named == dictation ? settle() : [.none]
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
  /// nothing. One naming another dictation is either its late notice, ignored,
  /// or the next dictation already running in ours' place, now under the latch.
  private mutating func follow(_ snapshot: PhaseSnapshot, dictation: UUID) -> [Action] {
    if let named = snapshot.dictation?.id, named != dictation {
      if !snapshot.state.isSettled { state = .foreign(dictation: named) }
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
    case .stopping(let id, let dictation, let sentAt, let resent):
      let age = now.timeIntervalSince(sentAt)
      // Past the deadline the app's watchdog ends the dictation; the line
      // for a transcription still running is `VoiceNotice`'s to show.
      if age >= stopDeadline { return settle() }
      guard !resent, age >= retryDelay else { return [.none] }
      state = .stopping(id: id, dictation: dictation, sentAt: sentAt, resent: true)
      return [.resendStop(id: id)]
    case .idle, .owned, .foreign, .unready:
      return [.none]
    }
  }

  private mutating func stateChanged(_ record: ListeningState?, now: Date) -> [Action] {
    if let record, record.isReady(now: now) {
      if case .unready = state { state = .idle }
      return [.none]
    }
    let reason = record?.notReady(now: now) ?? .sessionOff
    switch state {
    case .owned, .stopping:
      // A phase carrying our dictation is trusted over the record until it
      // is stale, and a stop already out has its own deadline.
      return [.none]
    case .pressing, .foreign:
      return refuse(reason)
    case .idle, .unready:
      state = .unready(reason)
      return [.show(reason)]
    }
  }

  /// The press is over without a dictation: the gate comes up, the line
  /// says why, and the next lift hops. No haptic — the line is the answer.
  private mutating func refuse(_ reason: FailureReason) -> [Action] {
    state = .unready(reason)
    return [.resetGate, .show(reason)]
  }

  /// The dictation is over, however it ended: nothing for the gate to hold.
  private mutating func settle() -> [Action] {
    state = .idle
    return [.resetGate]
  }
}
