import Foundation

/// The app's answer to one keyboard command, decided from values alone: the
/// command, the listening record, the coordinator's phase, the dictation in
/// flight and who owns it, who is on screen, and which ids were answered
/// before and how. `DictationCoordinator` reads a command, calls `route`,
/// writes the ack (`SharedStore.acknowledge`) and carries out the submit; the
/// decision itself reads no store and no clock, so every row is a test
/// (`CommandRouterTests`).
///
/// The rows, in the order they are tried:
///
/// - any command whose id was answered → the same outcome again (the
///   keyboard's resend sees `started(d)`, not a second answer), nothing
///   submitted, nothing to remember. `CommandAck.Outcome.duplicate` stays in
///   the contract for older acks; the router no longer produces it;
/// - any command older than `BlurtShared.commandFreshnessWindow` → `stale`;
/// - a press with no record, or a window that is not open → `notListening`
///   with the record's own reason (`reasonForPress`), `sessionOff` without a
///   record. It is never submitted: a press to a closed window is what the
///   keyboard's hop exists for;
/// - a press to an open window whose mic is not live → `notListening(micBusy)`;
/// - a press with the phase terminal → `started(new id)`, submit `.press`,
///   owned by the keyboard process that sent it;
/// - a press with a dictation in flight → `busy(its id)`, so the keyboard
///   latches onto it;
/// - a release or cancel with nothing in flight — the phase terminal, or no
///   ref — → `nothingInFlight`;
/// - a release or cancel for the dictation in flight (its id, or none named)
///   from the keyboard that owns it, or from the keyboard on screen →
///   `stopped` / `cancelled(its id)`, submit `.release` / `.cancel`,
///   addressed to the keyboard that sent it (`Decision.recipient`);
/// - any other release or cancel → `notOwner`.
///
/// "In flight" means the same thing for every row: the phase is not
/// terminal *and* a ref says which dictation. The phase says whether a
/// dictation is running; `inFlight` says which; the coordinator sets the two
/// together, and a ref left from a finished dictation blocks nothing. The
/// record's window and `micLive` are trusted as written: the app answering
/// is the proof it is alive, so the lease is not consulted, and a lapsed
/// lease never acks `suspended` — that reason is the keyboard's to derive.
package nonisolated enum CommandRouter {
  /// Everything one decision is made from.
  package nonisolated struct Input: Sendable {
    package let command: KeyboardCommand
    /// The app's listening record; nil before the first publish.
    package let state: ListeningState?
    /// The coordinator's overlay phase: whether a dictation is in flight.
    package let phase: PhaseSnapshot.State
    /// The dictation in flight and its owner; nil once the phase is terminal.
    package let inFlight: DictationRef?
    /// The keyboard process on screen (`SharedStore.keyboardOnScreen`), if any.
    package let onScreen: String?
    /// Command ids already answered, and how: a resend gets the same answer.
    package let answered: [UUID: CommandAck.Outcome]
    package let now: Date
    /// This app process, stamped on the ack.
    package let launchID: UUID
    /// The id a press that starts a dictation gets. Drawn here rather than in
    /// `route`, so the decision is a function of its input; the coordinator
    /// keeps the default.
    package let newDictationID: UUID

    package init(
      command: KeyboardCommand, state: ListeningState?, phase: PhaseSnapshot.State, inFlight: DictationRef?,
      onScreen: String?, answered: [UUID: CommandAck.Outcome], now: Date = Date(), launchID: UUID,
      newDictationID: UUID = UUID()
    ) {
      self.command = command
      self.state = state
      self.phase = phase
      self.inFlight = inFlight
      self.onScreen = onScreen
      self.answered = answered
      self.now = now
      self.launchID = launchID
      self.newDictationID = newDictationID
    }
  }

  /// What the coordinator does to the session after writing the ack.
  package nonisolated enum Submit: Sendable, Equatable {
    /// Start a dictation with this id, owned by the keyboard process that
    /// pressed (nil for a press that named none).
    case press(newDictation: UUID, owner: String?)
    case release
    case cancel
  }

  package nonisolated struct Decision: Sendable, Equatable {
    package let ack: CommandAck
    package let submit: Submit?
    /// Add the command's id and this outcome to `answered`, so its resend is
    /// answered the same way. False only for a resend, which is there already.
    package let remember: Bool
    /// For an accepted release or cancel: the keyboard process that sent it
    /// (`KeyboardCommand.keyboard`), so the coordinator addresses the result
    /// without reading the command again. Nil for every other decision.
    package let recipient: String?
  }

  package static func route(_ input: Input) -> Decision {
    let command = input.command
    if let before = input.answered[command.id] { return answer(input, before, remember: false) }
    guard command.isFresh(now: input.now) else { return answer(input, .stale) }
    switch command.kind {
    case .press: return press(input)
    case .release: return ending(input, submit: .release, outcome: CommandAck.Outcome.stopped)
    case .cancel: return ending(input, submit: .cancel, outcome: CommandAck.Outcome.cancelled)
    }
  }

  /// Why a press would be refused, from the record alone; nil when it would
  /// record. The record's own reason (`ListeningState.notReady`) — except
  /// `suspended`, which a lapsed lease yields and which the app, answering,
  /// plainly is not: that is answered from the window instead.
  package static func reasonForPress(state: ListeningState?, now: Date) -> FailureReason? {
    guard let state else { return .sessionOff }
    if state.window == .open { return state.micLive ? nil : .micBusy }
    guard let reason = state.notReady(now: now), reason != .suspended else { return windowReason(state.window) }
    return reason
  }

  /// The reason a window that is not recording stands for, with nothing else known.
  private static func windowReason(_ window: ListeningState.Window) -> FailureReason {
    switch window {
    case .closed, .closing: .sessionOff
    case .opening: .opening
    case .interrupted: .interrupted
    case .open: .micBusy
    }
  }

  private static func press(_ input: Input) -> Decision {
    if let reason = reasonForPress(state: input.state, now: input.now) {
      return answer(input, .notListening(reason))
    }
    guard isTerminal(input.phase) else {
      // A dictation is running that no press of the keyboard's started, so
      // there is no id to latch onto: the microphone is simply taken.
      guard let current = input.inFlight else { return answer(input, .notListening(.micBusy)) }
      return answer(input, .busy(current.id))
    }
    let dictationID = input.newDictationID
    return answer(
      input, .started(dictationID), submit: .press(newDictation: dictationID, owner: input.command.keyboard))
  }

  private static func ending(
    _ input: Input, submit: Submit, outcome: (UUID) -> CommandAck.Outcome
  ) -> Decision {
    guard !isTerminal(input.phase), let current = input.inFlight else { return answer(input, .nothingInFlight) }
    guard mayEnd(input.command, current, onScreen: input.onScreen) else { return answer(input, .notOwner) }
    return answer(input, outcome(current.id), submit: submit, recipient: input.command.keyboard)
  }

  /// Whether this command may end the dictation in flight: it names that
  /// dictation (or none, for a keyboard build that never learned the id),
  /// and it comes from the owner or from the keyboard on screen. A command
  /// with no process id matches an owner with none — a dictation nobody
  /// owns, ended the old way — but never stands in for the keyboard on
  /// screen: that match needs both sides named.
  private static func mayEnd(_ command: KeyboardCommand, _ current: DictationRef, onScreen: String?) -> Bool {
    guard command.dictationID == nil || command.dictationID == current.id else { return false }
    if command.keyboard == current.ownerProcessID { return true }
    guard let sender = command.keyboard, let onScreen else { return false }
    return sender == onScreen
  }

  /// A phase that is over: the next press starts a new dictation, and there
  /// is nothing for a release or cancel to end.
  private static func isTerminal(_ phase: PhaseSnapshot.State) -> Bool {
    switch phase {
    case .idle, .pasted, .copied, .error: true
    case .connecting, .recording, .processing: false
    }
  }

  private static func answer(
    _ input: Input, _ outcome: CommandAck.Outcome, submit: Submit? = nil, remember: Bool = true,
    recipient: String? = nil
  ) -> Decision {
    let ack = CommandAck(commandID: input.command.id, launchID: input.launchID, outcome: outcome, at: input.now)
    return Decision(ack: ack, submit: submit, remember: remember, recipient: recipient)
  }
}
