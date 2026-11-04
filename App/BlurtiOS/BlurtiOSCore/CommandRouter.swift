import Foundation

/// The app's answer to one keyboard command, decided from values alone: the
/// command, the listening record, the coordinator's phase, the dictation in
/// flight and who owns it, who is on screen, and which ids were answered
/// before. `DictationCoordinator` reads a command, calls `route`, writes the
/// ack (`SharedStore.acknowledge`) and carries out the submit; the decision
/// itself reads no store and no clock, so every row is a test
/// (`CommandRouterTests`).
///
/// The rows, in the order they are tried:
///
/// - any command whose id was answered → `duplicate` (the keyboard's resend);
/// - any command older than `BlurtShared.commandFreshnessWindow` → `stale`;
/// - a press with no record, or a window that is not open → `notListening`
///   with the record's own reason (`ListeningState.notReady`), `sessionOff`
///   without a record. It is never submitted: a press to a closed window is
///   what the keyboard's hop exists for;
/// - a press to an open window whose mic is not live → `notListening(micBusy)`;
/// - a press with the phase terminal → `started(new id)`, submit `.press`,
///   owned by the keyboard process that sent it;
/// - a press with a dictation in flight → `busy(its id)`, so the keyboard
///   latches onto it;
/// - a release or cancel with nothing in flight → `nothingInFlight`;
/// - a release or cancel for the dictation in flight (its id, or none named)
///   from the keyboard that owns it, or from the keyboard on screen →
///   `stopped` / `cancelled(its id)`, submit `.release` / `.cancel`;
/// - any other release or cancel → `notOwner`.
///
/// The phase says whether a dictation is running; `inFlight` says which, and
/// the coordinator sets the two together. The record's window and `micLive`
/// are trusted as written: the app answering is the proof it is alive, so
/// the lease is not consulted.
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
    /// Command ids already answered.
    package let seen: Set<UUID>
    package let now: Date
    /// This app process, stamped on the ack.
    package let launchID: UUID
    /// The id a press that starts a dictation gets. Drawn here rather than in
    /// `route`, so the decision is a function of its input; the coordinator
    /// keeps the default.
    package let newDictationID: UUID

    package init(
      command: KeyboardCommand, state: ListeningState?, phase: PhaseSnapshot.State, inFlight: DictationRef?,
      onScreen: String?, seen: Set<UUID>, now: Date = Date(), launchID: UUID, newDictationID: UUID = UUID()
    ) {
      self.command = command
      self.state = state
      self.phase = phase
      self.inFlight = inFlight
      self.onScreen = onScreen
      self.seen = seen
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
    /// Add the command's id to `seen`, so its resend is answered `duplicate`.
    /// False only for a duplicate, which is there already.
    package let remember: Bool
  }

  package static func route(_ input: Input) -> Decision {
    let command = input.command
    if input.seen.contains(command.id) { return answer(input, .duplicate, remember: false) }
    guard command.isFresh(now: input.now) else { return answer(input, .stale) }
    switch command.kind {
    case .press: return press(input)
    case .release: return ending(input, submit: .release, outcome: CommandAck.Outcome.stopped)
    case .cancel: return ending(input, submit: .cancel, outcome: CommandAck.Outcome.cancelled)
    }
  }

  private static func press(_ input: Input) -> Decision {
    guard let state = input.state, state.window == .open else {
      return answer(input, .notListening(input.state?.notReady(now: input.now) ?? .sessionOff))
    }
    guard state.micLive else { return answer(input, .notListening(.micBusy)) }
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
    guard let current = input.inFlight else { return answer(input, .nothingInFlight) }
    guard mayEnd(input.command, current, onScreen: input.onScreen) else { return answer(input, .notOwner) }
    return answer(input, outcome(current.id), submit: submit)
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

  /// A phase that is over: the next press starts a new dictation.
  private static func isTerminal(_ phase: PhaseSnapshot.State) -> Bool {
    switch phase {
    case .idle, .pasted, .copied, .error: true
    case .connecting, .recording, .processing: false
    }
  }

  private static func answer(
    _ input: Input, _ outcome: CommandAck.Outcome, submit: Submit? = nil, remember: Bool = true
  ) -> Decision {
    let ack = CommandAck(commandID: input.command.id, launchID: input.launchID, outcome: outcome, at: input.now)
    return Decision(ack: ack, submit: submit, remember: remember)
  }
}
