import Foundation

// MARK: - The handshake's vocabulary
//
// The states, events and actions `PressHandshake` is written in. Values only,
// so a test states a row as "this event, in this state, lands here and asks
// for these".

extension PressHandshake {
  package nonisolated enum State: Sendable, Equatable {
    case idle
    /// Our press is out and unanswered. `stopWanted`: the finger came down
    /// again, or a hold lifted, before the answer came. The one command slot holds our press
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
    /// latched over it, and the next finger down, or a hold's lift, releases
    /// it. From `busy` the press latched onto it without a stop: the press
    /// didn't knowingly land on a running dictation.
    case foreign(dictation: UUID)
    /// A press would not record; the next lift hops with the reason.
    case unready(FailureReason)
  }

  package nonisolated enum Event: Sendable, Equatable {
    /// Finger down: whether the record says a press records now (and why
    /// not), the phase on screen and the dictation it names.
    case micDown(ready: Bool, reason: FailureReason?, phase: PhaseSnapshot.State, inFlight: DictationRef?)
    /// Finger up, with how long it was down: a hold's lift stops, a tap's
    /// sends nothing, and a refused press hops.
    case micUp(heldFor: TimeInterval)
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
    /// Latch the gate over a dictation this keyboard didn't start, so the gate
    /// holds it until it ends: the synthetic `modifierDown` + `modifierUp`, only if
    /// `gate.isIdle` — the finger may be down, or a tap may have latched it.
    case latch
    case showConnecting
    case show(FailureReason)
    case hop(FailureReason?)
    /// The warning haptic: the words are still being made, nothing to press.
    case buzz
    case nothing
  }
}
