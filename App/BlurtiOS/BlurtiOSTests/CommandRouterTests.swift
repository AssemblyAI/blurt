import Foundation
import Testing

@testable import BlurtiOSCore

/// Every row of the router's table, over values alone: no store, no clock.
/// The fixtures are shared with `CommandRouterTests+Ending.swift`, the
/// release and cancel rows.
@Suite("Command router")
struct CommandRouterTests {
  static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  static let launchID = UUID()
  /// An open window with a live mic, the record most rows start from.
  static let open = ListeningState(
    launchID: launchID, sequence: 1, window: .open, micLive: true, writtenAt: now)

  let owner = "keyboard-owner"
  let other = "keyboard-other"
  let current = DictationRef(id: UUID(), ownerProcessID: "keyboard-owner")

  func command(
    _ kind: KeyboardCommand.Kind, keyboard: String? = "keyboard-owner", dictationID: UUID? = nil,
    age: TimeInterval = 0
  ) -> KeyboardCommand {
    KeyboardCommand(
      id: UUID(), kind: kind, priorText: nil, selectedText: nil, sentAt: Self.now.addingTimeInterval(-age),
      keyboard: keyboard, dictationID: dictationID)
  }

  func record(
    _ window: ListeningState.Window, micLive: Bool = true, reason: FailureReason? = nil, leaseLapsed: Bool = false
  ) -> ListeningState {
    let writtenAt = leaseLapsed ? Self.now.addingTimeInterval(-(ListeningState.lease + 1)) : Self.now
    return ListeningState(
      launchID: Self.launchID, sequence: 1, window: window, micLive: micLive, reason: reason, writtenAt: writtenAt)
  }

  func route(
    _ command: KeyboardCommand, state: ListeningState? = CommandRouterTests.open, phase: PhaseSnapshot.State = .idle,
    inFlight: DictationRef? = nil, onScreen: String? = nil, answered: [UUID: CommandAck.Outcome] = [:],
    newDictationID: UUID = UUID()
  ) -> CommandRouter.Decision {
    CommandRouter.route(
      CommandRouter.Input(
        command: command, state: state, phase: phase, inFlight: inFlight, onScreen: onScreen, answered: answered,
        now: Self.now, launchID: Self.launchID, newDictationID: newDictationID))
  }

  func startedID(_ decision: CommandRouter.Decision) -> UUID? {
    if case .started(let id) = decision.ack.outcome { return id }
    return nil
  }

  // MARK: Any command

  @Test("the ack names the command, this launch and the moment it was decided")
  func ackIdentity() {
    let press = command(.press)
    let decision = route(press)
    #expect(decision.ack.commandID == press.id)
    #expect(decision.ack.launchID == Self.launchID)
    #expect(decision.ack.at == Self.now)
  }

  @Test("an id answered before gets its answer again, with nothing submitted and nothing to remember")
  func resendIsAnsweredAgain() {
    let press = command(.press)
    let before = CommandAck.Outcome.notListening(.opening)
    let decision = route(press, answered: [press.id: before])
    #expect(decision.ack.outcome == before)
    #expect(decision.ack.commandID == press.id)
    #expect(decision.ack.at == Self.now)
    #expect(decision.submit == nil)
    #expect(!decision.remember)
    #expect(decision.recipient == nil)
  }

  @Test("the router never answers duplicate: a resend carries the original outcome, never that word")
  func duplicateNeverProduced() {
    let press = command(.press)
    let first = route(press)
    let resend = route(press, phase: .recording, inFlight: current, answered: [press.id: first.ack.outcome])
    #expect(resend.ack.outcome != .duplicate)
  }

  @Test("a resend of a started press is started with the same id: the keyboard keeps its own dictation")
  func resendOfStartedPress() throws {
    let press = command(.press)
    let first = route(press)
    let started = DictationRef(id: try #require(startedID(first)), ownerProcessID: owner)
    #expect(first.remember)
    let resend = route(press, phase: .recording, inFlight: started, answered: [press.id: first.ack.outcome])
    #expect(resend.ack.outcome == .started(started.id))
    #expect(resend.submit == nil)
    #expect(!resend.remember)
  }

  @Test("a resend of a refused press is refused the same way, whatever the record says now")
  func resendOfRefusedPress() {
    let press = command(.press)
    let first = route(press, state: record(.closed, reason: .sessionOff))
    #expect(first.ack.outcome == .notListening(.sessionOff))
    let resend = route(press, state: Self.open, answered: [press.id: first.ack.outcome])
    #expect(resend.ack.outcome == .notListening(.sessionOff))
    #expect(resend.submit == nil)
  }

  @Test("a command older than the freshness window is stale, and never submitted")
  func stale() {
    for kind in [KeyboardCommand.Kind.press, .release, .cancel] {
      let old = command(kind, age: BlurtShared.commandFreshnessWindow + 1)
      let decision = route(old, phase: .recording, inFlight: current)
      #expect(decision.ack.outcome == .stale, "\(kind)")
      #expect(decision.submit == nil)
      #expect(decision.remember)
      #expect(decision.recipient == nil)
    }
  }

  @Test("the answered check comes first, so a stale resend gets its first answer, not stale")
  func staleResend() {
    let old = command(.press, age: BlurtShared.commandFreshnessWindow + 1)
    let dictationID = UUID()
    #expect(route(old, answered: [old.id: .started(dictationID)]).ack.outcome == .started(dictationID))
  }

  // MARK: Press

  @Test("a press with no record at all is not listening: the session is off")
  func pressNoRecord() {
    let decision = route(command(.press), state: nil)
    #expect(decision.ack.outcome == .notListening(.sessionOff))
    #expect(decision.submit == nil)
    #expect(decision.recipient == nil)
  }

  @Test("a press to a window that is not open is never submitted, and carries the record's reason")
  func pressClosedWindow() {
    let cases: [(record: ListeningState, expected: FailureReason)] = [
      (record(.closed, reason: .sessionOff), .sessionOff),
      (record(.closed), .sessionOff),
      (record(.closing), .sessionOff),
      (record(.opening), .opening),
      (record(.interrupted), .interrupted),
      (record(.closed, reason: .needsForeground), .needsForeground),
    ]
    for (record, expected) in cases {
      let decision = route(command(.press), state: record)
      #expect(decision.ack.outcome == .notListening(expected), "\(record.window) \(String(describing: record.reason))")
      #expect(decision.submit == nil)
    }
  }

  @Test("the app never acks suspended: a lapsed lease is answered from the window, for each window")
  func pressLapsedLeaseEachWindow() {
    let cases: [(record: ListeningState, expected: FailureReason)] = [
      (record(.closed, leaseLapsed: true), .sessionOff),
      (record(.closed, reason: .needsForeground, leaseLapsed: true), .sessionOff),
      (record(.closing, leaseLapsed: true), .sessionOff),
      (record(.opening, leaseLapsed: true), .opening),
      (record(.interrupted, leaseLapsed: true), .interrupted),
      (record(.open, micLive: false, leaseLapsed: true), .micBusy),
    ]
    for (record, expected) in cases {
      #expect(record.notReady(now: Self.now) == .suspended, "\(record.window)")
      let decision = route(command(.press), state: record)
      #expect(decision.ack.outcome == .notListening(expected), "\(record.window)")
      #expect(decision.submit == nil)
    }
  }

  @Test("reasonForPress: nil for an open live record, the record's reason otherwise, never suspended")
  func reasonForPress() {
    #expect(CommandRouter.reasonForPress(state: nil, now: Self.now) == .sessionOff)
    #expect(CommandRouter.reasonForPress(state: Self.open, now: Self.now) == nil)
    #expect(CommandRouter.reasonForPress(state: record(.open, leaseLapsed: true), now: Self.now) == nil)
    #expect(CommandRouter.reasonForPress(state: record(.open, micLive: false), now: Self.now) == .micBusy)
    #expect(CommandRouter.reasonForPress(state: record(.closed, reason: .noKey), now: Self.now) == .noKey)
    #expect(CommandRouter.reasonForPress(state: record(.interrupted), now: Self.now) == .interrupted)
    for window in [ListeningState.Window.closed, .closing, .opening, .interrupted, .open] {
      let lapsed = record(window, micLive: false, leaseLapsed: true)
      #expect(CommandRouter.reasonForPress(state: lapsed, now: Self.now) != .suspended, "\(window)")
    }
  }

  @Test("a press to an open window whose mic is not live is refused as mic busy")
  func pressMicNotLive() {
    let decision = route(command(.press), state: record(.open, micLive: false))
    #expect(decision.ack.outcome == .notListening(.micBusy))
    #expect(decision.submit == nil)
  }

  @Test("a press with the phase terminal starts a dictation owned by the keyboard that pressed")
  func pressStarts() {
    let dictationID = UUID()
    for phase in [PhaseSnapshot.State.idle, .pasted, .copied, .error] {
      let decision = route(command(.press), phase: phase, newDictationID: dictationID)
      #expect(decision.ack.outcome == .started(dictationID), "\(phase)")
      #expect(decision.submit == .press(newDictation: dictationID, owner: owner))
      #expect(decision.remember)
      #expect(decision.recipient == nil)
    }
  }

  @Test("the started ack and the submitted press agree on the new dictation's id")
  func pressIDsAgree() throws {
    let decision = route(command(.press))
    let acked = try #require(startedID(decision))
    #expect(decision.submit == .press(newDictation: acked, owner: owner))
  }

  @Test("a press from a keyboard with no process id starts a dictation nobody owns")
  func pressWithoutProcessID() {
    let dictationID = UUID()
    let decision = route(command(.press, keyboard: nil), newDictationID: dictationID)
    #expect(decision.submit == .press(newDictation: dictationID, owner: nil))
  }

  @Test("a press with a dictation in flight latches onto it: busy, nothing submitted")
  func pressBusy() {
    for phase in [PhaseSnapshot.State.connecting, .recording, .processing] {
      let decision = route(command(.press, keyboard: other), phase: phase, inFlight: current)
      #expect(decision.ack.outcome == .busy(current.id), "\(phase)")
      #expect(decision.submit == nil)
      #expect(decision.recipient == nil)
    }
  }

  @Test("a new press from the owner's own process while its dictation is in flight is busy too")
  func pressFromOwnerWhileInFlight() {
    let decision = route(command(.press, keyboard: owner), phase: .recording, inFlight: current)
    #expect(decision.ack.outcome == .busy(current.id))
    #expect(decision.submit == nil)
    #expect(decision.remember)
  }

  @Test("a press while something runs that no press started has no id to latch onto: mic busy")
  func pressBusyWithoutRef() {
    let decision = route(command(.press), phase: .recording, inFlight: nil)
    #expect(decision.ack.outcome == .notListening(.micBusy))
    #expect(decision.submit == nil)
  }

  @Test("the phase says whether a dictation runs: a ref left from a finished one does not block a press")
  func pressOverStaleRef() {
    #expect(route(command(.press), phase: .pasted, inFlight: current).submit != nil)
  }

  @Test("the window and the mic are read as written: a lapsed lease does not refuse a press")
  func pressLapsedLease() {
    #expect(route(command(.press), state: record(.open, leaseLapsed: true)).submit != nil)
  }
}
