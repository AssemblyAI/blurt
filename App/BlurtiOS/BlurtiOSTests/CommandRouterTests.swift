import Foundation
import Testing

@testable import BlurtiOSCore

/// Every row of the router's table, over values alone: no store, no clock.
@Suite("Command router")
struct CommandRouterTests {
  private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private static let launchID = UUID()
  /// An open window with a live mic, the record most rows start from.
  private static let open = ListeningState(
    launchID: launchID, sequence: 1, window: .open, micLive: true, writtenAt: now)

  private let owner = "keyboard-owner"
  private let other = "keyboard-other"
  private let current = DictationRef(id: UUID(), ownerProcessID: "keyboard-owner")

  private func command(
    _ kind: KeyboardCommand.Kind, keyboard: String? = "keyboard-owner", dictationID: UUID? = nil,
    age: TimeInterval = 0
  ) -> KeyboardCommand {
    KeyboardCommand(
      id: UUID(), kind: kind, priorText: nil, selectedText: nil, sentAt: Self.now.addingTimeInterval(-age),
      keyboard: keyboard, dictationID: dictationID)
  }

  private func record(_ window: ListeningState.Window, micLive: Bool = true, reason: FailureReason? = nil)
    -> ListeningState
  {
    ListeningState(
      launchID: Self.launchID, sequence: 1, window: window, micLive: micLive, reason: reason, writtenAt: Self.now)
  }

  private func route(
    _ command: KeyboardCommand, state: ListeningState? = CommandRouterTests.open, phase: PhaseSnapshot.State = .idle,
    inFlight: DictationRef? = nil, onScreen: String? = nil, seen: Set<UUID> = [], newDictationID: UUID = UUID()
  ) -> CommandRouter.Decision {
    CommandRouter.route(
      CommandRouter.Input(
        command: command, state: state, phase: phase, inFlight: inFlight, onScreen: onScreen, seen: seen,
        now: Self.now, launchID: Self.launchID, newDictationID: newDictationID))
  }

  private func startedID(_ decision: CommandRouter.Decision) -> UUID? {
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

  @Test("an id answered before is a duplicate, with nothing submitted and nothing to remember")
  func duplicate() {
    let press = command(.press)
    let decision = route(press, seen: [press.id])
    #expect(decision.ack.outcome == .duplicate)
    #expect(decision.submit == nil)
    #expect(!decision.remember)
  }

  @Test("a resend after the ack is a duplicate, not a second dictation and not busy")
  func resendAfterAck() throws {
    let press = command(.press)
    let first = route(press)
    let started = DictationRef(id: try #require(startedID(first)), ownerProcessID: owner)
    #expect(first.remember)
    let resend = route(press, phase: .recording, inFlight: started, seen: [press.id])
    #expect(resend.ack.outcome == .duplicate)
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
    }
  }

  @Test("the duplicate check comes first, so a stale resend is still a duplicate")
  func staleDuplicate() {
    let old = command(.press, age: BlurtShared.commandFreshnessWindow + 1)
    #expect(route(old, seen: [old.id]).ack.outcome == .duplicate)
  }

  // MARK: Press

  @Test("a press with no record at all is not listening: the session is off")
  func pressNoRecord() {
    let decision = route(command(.press), state: nil)
    #expect(decision.ack.outcome == .notListening(.sessionOff))
    #expect(decision.submit == nil)
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
    }
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
    let lapsed = ListeningState(
      launchID: Self.launchID, sequence: 1, window: .open, micLive: true,
      writtenAt: Self.now.addingTimeInterval(-(ListeningState.lease + 1)))
    #expect(route(command(.press), state: lapsed).submit != nil)
  }

  // MARK: Release and cancel

  @Test("a release or cancel with nothing in flight has nothing to end")
  func nothingInFlight() {
    for kind in [KeyboardCommand.Kind.release, .cancel] {
      let decision = route(command(kind), phase: .idle, inFlight: nil)
      #expect(decision.ack.outcome == .nothingInFlight, "\(kind)")
      #expect(decision.submit == nil)
      #expect(decision.remember)
    }
  }

  @Test("the owner's release stops the dictation in flight")
  func ownerRelease() {
    let decision = route(command(.release, dictationID: current.id), phase: .recording, inFlight: current)
    #expect(decision.ack.outcome == .stopped(current.id))
    #expect(decision.submit == .release)
    #expect(decision.remember)
  }

  @Test("the owner's cancel cancels it")
  func ownerCancel() {
    let decision = route(command(.cancel, dictationID: current.id), phase: .recording, inFlight: current)
    #expect(decision.ack.outcome == .cancelled(current.id))
    #expect(decision.submit == .cancel)
  }

  @Test("a release that names no dictation ends the one in flight")
  func releaseWithoutDictationID() {
    let decision = route(command(.release), phase: .connecting, inFlight: current)
    #expect(decision.ack.outcome == .stopped(current.id))
    #expect(decision.submit == .release)
  }

  @Test("a release for an older dictation is not the owner's to make")
  func releaseOlderDictation() {
    let decision = route(command(.release, dictationID: UUID()), phase: .recording, inFlight: current)
    #expect(decision.ack.outcome == .notOwner)
    #expect(decision.submit == nil)
  }

  @Test("a release from the keyboard on screen is accepted though it is not the owner")
  func releaseFromOnScreen() {
    let decision = route(command(.release, keyboard: other), phase: .recording, inFlight: current, onScreen: other)
    #expect(decision.ack.outcome == .stopped(current.id))
    #expect(decision.submit == .release)
  }

  @Test("a cancel from the keyboard on screen is accepted too")
  func cancelFromOnScreen() {
    let decision = route(command(.cancel, keyboard: other), phase: .recording, inFlight: current, onScreen: other)
    #expect(decision.ack.outcome == .cancelled(current.id))
    #expect(decision.submit == .cancel)
  }

  @Test("a release from a keyboard that neither owns the dictation nor is on screen is refused")
  func releaseNotOwner() {
    for onScreen in [nil, owner, "keyboard-third"] {
      let decision = route(command(.release, keyboard: other), phase: .recording, inFlight: current, onScreen: onScreen)
      #expect(decision.ack.outcome == .notOwner, "on screen: \(String(describing: onScreen))")
      #expect(decision.submit == nil)
      #expect(decision.remember)
    }
  }

  @Test("the on-screen match needs both sides named: an unnamed sender never passes as the keyboard on screen")
  func releaseUnnamedSender() {
    #expect(route(command(.release, keyboard: nil), phase: .recording, inFlight: current).ack.outcome == .notOwner)
    #expect(
      route(command(.release, keyboard: nil), phase: .recording, inFlight: current, onScreen: owner).ack.outcome
        == .notOwner)
  }

  @Test("a dictation nobody owns is ended by a command that names no sender, the old way")
  func releaseUnownedDictation() {
    let unowned = DictationRef(id: UUID(), ownerProcessID: nil)
    let decision = route(command(.release, keyboard: nil), phase: .recording, inFlight: unowned)
    #expect(decision.ack.outcome == .stopped(unowned.id))
    #expect(decision.submit == .release)
    #expect(route(command(.release, keyboard: other), phase: .recording, inFlight: unowned).ack.outcome == .notOwner)
  }

  @Test("a stop resent after its ack is a duplicate, so the session is not told twice")
  func stopResend() {
    let release = command(.release, dictationID: current.id)
    #expect(route(release, phase: .recording, inFlight: current).submit == .release)
    let resend = route(release, phase: .processing, inFlight: current, seen: [release.id])
    #expect(resend.ack.outcome == .duplicate)
    #expect(resend.submit == nil)
  }
}
