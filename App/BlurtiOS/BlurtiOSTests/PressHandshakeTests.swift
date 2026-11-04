import BlurtEngine
import Foundation
import Testing

@testable import BlurtiOSCore

/// One handshake's world: a fixed clock, one app launch, and the events as
/// the model would build them. Shared with `PressHandshakeStopTests` and
/// `PressHandshakeGateTests`.
enum HandshakeFixture {
  static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  static let app = UUID()

  static let tap = PressHandshake.Event.micUp(armedFromIdle: true, heldFor: 0.2)
  static let hold = PressHandshake.Event.micUp(armedFromIdle: true, heldFor: 1.2)
  static let liftOverLatch = PressHandshake.Event.micUp(armedFromIdle: false, heldFor: 0.1)

  static func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

  static func ack(_ outcome: CommandAck.Outcome, for id: UUID) -> PressHandshake.Event {
    .ack(CommandAck(commandID: id, launchID: app, outcome: outcome, at: epoch))
  }

  static func published(
    _ state: PhaseSnapshot.State, answers: UUID? = nil, dictation: UUID? = nil, reason: FailureReason? = nil
  ) -> PressHandshake.Event {
    .phase(
      PhaseSnapshot(
        state: state, message: nil, level: 0, at: epoch, reason: reason, answers: answers,
        dictation: dictation.map { DictationRef(id: $0, ownerProcessID: nil) }))
  }

  static func record(
    _ window: ListeningState.Window, micLive: Bool = true, reason: FailureReason? = nil
  ) -> ListeningState {
    ListeningState(launchID: app, sequence: 1, window: window, micLive: micLive, reason: reason, writtenAt: epoch)
  }

  static func micDown(
    ready: Bool = true, reason: FailureReason? = nil, phase: PhaseSnapshot.State = .idle, inFlight: UUID? = nil
  ) -> PressHandshake.Event {
    let ref = inFlight.map { DictationRef(id: $0, ownerProcessID: nil) }
    return .micDown(ready: ready, reason: reason, phase: phase, inFlight: ref)
  }

  /// A press from rest, out and unanswered.
  static func pressed(_ handshake: inout PressHandshake) -> UUID {
    _ = handshake.handle(micDown(), now: epoch)
    let id = UUID()
    _ = handshake.handle(.pressSent(id: id, at: epoch), now: epoch)
    return id
  }

  /// A tap from rest the app answered: the keyboard owns the dictation, at `phase`.
  static func owned(_ handshake: inout PressHandshake, phase: PhaseSnapshot.State = .connecting) -> UUID {
    let id = pressed(&handshake)
    _ = handshake.handle(tap, now: epoch)
    let dictation = UUID()
    _ = handshake.handle(ack(.started(dictation), for: id), now: epoch)
    if phase != .connecting { _ = handshake.handle(published(phase, dictation: dictation), now: epoch) }
    return dictation
  }

  /// A press from rest the app answered with busy, the finger still down:
  /// latched onto their dictation.
  static func foreignViaBusy(_ handshake: inout PressHandshake) -> UUID {
    let id = pressed(&handshake)
    let dictation = UUID()
    _ = handshake.handle(ack(.busy(dictation), for: id), now: epoch)
    return dictation
  }

  /// A finger down from rest over their dictation, visibly running.
  static func foreignViaLatch(_ handshake: inout PressHandshake) -> UUID {
    let dictation = UUID()
    _ = handshake.handle(micDown(phase: .recording, inFlight: dictation), now: epoch)
    return dictation
  }
}

// `#expect` captures its expression immutably, so each mutating step lands
// in a local first.
@Suite("Press handshake: the press and its answers")
struct PressHandshakeTests {
  typealias Fixture = HandshakeFixture
  let epoch = Fixture.epoch

  @Test("the numbers are the contract's: the deadlines, the gate's hold, the model's retry")
  @MainActor
  func numbers() {
    let handshake = PressHandshake()
    #expect(handshake.pressDeadline == BlurtShared.pressDeadline)
    #expect(handshake.stopDeadline == BlurtShared.stopDeadline)
    #expect(Duration.seconds(handshake.retryDelay) == KeyboardModel.commandRetryDelay)
    #expect(Duration.seconds(handshake.holdThreshold) == DictationKeyGate().holdThreshold)
    #expect(handshake.retryDelay < handshake.pressDeadline)
  }

  @Test("a press from rest arms the gate and goes out with a connecting picture; pressing once sent")
  func press() {
    var handshake = PressHandshake()
    let down = handshake.handle(Fixture.micDown(), now: epoch)
    #expect(down == [.armGate, .sendPress, .showConnecting])
    #expect(handshake.isIdle)
    let id = UUID()
    let sent = handshake.handle(.pressSent(id: id, at: epoch), now: epoch)
    #expect(sent == [.none])
    #expect(handshake.state == .pressing(id: id, sentAt: epoch, resent: false, stopWanted: false))
    #expect(handshake.pressID == id)
    #expect(handshake.dictationID == nil)
    #expect(!handshake.isIdle && !handshake.isOwned)
  }

  @Test("an unanswered press is resent once at the retry delay, not before and not again")
  func resend() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let early = handshake.handle(.tick(now: Fixture.at(0.59)), now: Fixture.at(0.59))
    #expect(early == [.none])
    let due = handshake.handle(.tick(now: Fixture.at(0.6)), now: Fixture.at(0.6))
    #expect(due == [.resendPress(id: id)])
    let again = handshake.handle(.tick(now: Fixture.at(0.9)), now: Fixture.at(0.9))
    #expect(again == [.none])
    #expect(handshake.state == .pressing(id: id, sentAt: epoch, resent: true, stopWanted: false))
  }

  @Test("deadline → unready and resetGate, and the lift hops; never a dead release")
  func deadline() {
    var handshake = PressHandshake()
    _ = Fixture.pressed(&handshake)
    _ = handshake.handle(.tick(now: Fixture.at(0.6)), now: Fixture.at(0.6))
    let late = handshake.handle(.tick(now: Fixture.at(1.2)), now: Fixture.at(1.2))
    #expect(late == [.resetGate, .show(.unanswered)])
    #expect(handshake.state == .unready(.unanswered))
    #expect(handshake.unreadyReason == .unanswered)
    #expect(handshake.pressID == nil)
    let lift = handshake.handle(Fixture.hold, now: Fixture.at(1.3))
    #expect(lift == [.hop(.unanswered)])
    let ticks = handshake.handle(.tick(now: Fixture.at(5)), now: Fixture.at(5))
    #expect(ticks == [.none])
  }

  @Test("ack started → owned; the ack for another command is ignored")
  func started() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let other = handshake.handle(Fixture.ack(.started(UUID()), for: UUID()), now: epoch)
    #expect(other == [.none])
    #expect(handshake.pressID == id)
    let dictation = UUID()
    let answer = handshake.handle(Fixture.ack(.started(dictation), for: id), now: epoch)
    #expect(answer == [.none])
    #expect(handshake.state == .owned(dictation: dictation, phase: .connecting))
    #expect(handshake.isOwned && handshake.dictationID == dictation && handshake.pressID == nil)
  }

  @Test("in-flight phase answers when the ack is lost")
  func phaseAnswers() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let dictation = UUID()
    let answer = handshake.handle(
      Fixture.published(.recording, answers: id, dictation: dictation), now: Fixture.at(0.3))
    #expect(answer == [.none])
    #expect(handshake.state == .owned(dictation: dictation, phase: .recording))
    let late = handshake.handle(.tick(now: Fixture.at(2)), now: Fixture.at(2))
    #expect(late == [.none])
    #expect(handshake.isOwned)
  }

  @Test("a phase answering some other press, or naming no dictation, leaves the press waiting")
  func phaseForAnotherPress() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let previous = handshake.handle(Fixture.published(.pasted, answers: UUID(), dictation: UUID()), now: epoch)
    #expect(previous == [.none])
    let unnamed = handshake.handle(Fixture.published(.recording, answers: id), now: epoch)
    #expect(unnamed == [.none])
    #expect(handshake.pressID == id)
  }

  @Test("an error phase answering the press refuses it with the phase's reason")
  func phaseError() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let failed = handshake.handle(Fixture.published(.error, answers: id, reason: .micSilent), now: epoch)
    #expect(failed == [.resetGate, .show(.micSilent)])
    #expect(handshake.state == .unready(.micSilent))
  }

  @Test("a notice answering the press means the dictation already ended: idle")
  func phaseSettled() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let over = handshake.handle(Fixture.published(.pasted, answers: id, dictation: UUID()), now: epoch)
    #expect(over == [.resetGate])
    #expect(handshake.isIdle)
  }

  @Test("ack busy → foreign and a latch; the tap's own lift leaves it running, the next tap's lift stops it")
  func busy() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let dictation = UUID()
    let answer = handshake.handle(Fixture.ack(.busy(dictation), for: id), now: epoch)
    #expect(answer == [.latch])
    #expect(handshake.state == .foreign(dictation: dictation, liftStops: false))
    #expect(handshake.dictationID == dictation && !handshake.isOwned)
    let lift = handshake.handle(Fixture.tap, now: Fixture.at(0.2))
    #expect(lift == [.none])
    #expect(handshake.state == .foreign(dictation: dictation, liftStops: true))
    let down = handshake.handle(Fixture.micDown(phase: .recording, inFlight: dictation), now: Fixture.at(2))
    #expect(down == [.armGate])
    let stop = handshake.handle(Fixture.liftOverLatch, now: Fixture.at(2.1))
    #expect(stop == [.sendRelease(dictation: dictation)])
  }

  @Test("ack notListening → unready with its reason, gate reset, a line and no buzz")
  func notListening() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let refused = handshake.handle(Fixture.ack(.notListening(.interrupted), for: id), now: epoch)
    #expect(refused == [.resetGate, .show(.interrupted)])
    #expect(handshake.state == .unready(.interrupted))
    let lift = handshake.handle(Fixture.tap, now: epoch)
    #expect(lift == [.hop(.interrupted)])
  }

  @Test("ack stale, duplicate or nothingInFlight for the press keeps it waiting; the deadline settles it")
  func staleAndDuplicate() {
    for outcome in [CommandAck.Outcome.stale, .duplicate, .nothingInFlight] {
      var handshake = PressHandshake()
      let id = Fixture.pressed(&handshake)
      let kept = handshake.handle(Fixture.ack(outcome, for: id), now: Fixture.at(0.1))
      #expect(kept == [.none])
      #expect(handshake.state == .pressing(id: id, sentAt: epoch, resent: false, stopWanted: false))
      let late = handshake.handle(.tick(now: Fixture.at(1.2)), now: Fixture.at(1.2))
      #expect(late == [.resetGate, .show(.unanswered)])
      #expect(handshake.state == .unready(.unanswered))
    }
  }

  @Test("an answer at or past the deadline is late, tick or no tick: the press was given up")
  func lateAnswer() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    _ = handshake.handle(Fixture.hold, now: Fixture.at(1.1))
    let late = handshake.handle(Fixture.ack(.started(UUID()), for: id), now: Fixture.at(1.3))
    #expect(late == [.resetGate, .show(.unanswered)])
    #expect(handshake.state == .unready(.unanswered))
    var ticked = PressHandshake()
    let press = Fixture.pressed(&ticked)
    _ = ticked.handle(Fixture.hold, now: Fixture.at(1.1))
    _ = ticked.handle(.tick(now: Fixture.at(1.2)), now: Fixture.at(1.2))
    let ignored = ticked.handle(Fixture.ack(.started(UUID()), for: press), now: Fixture.at(1.3))
    #expect(ignored == [.none])
    #expect(ticked.state == .unready(.unanswered))
    var byPhase = PressHandshake()
    let other = Fixture.pressed(&byPhase)
    let phase = byPhase.handle(
      Fixture.published(.recording, answers: other, dictation: UUID()), now: Fixture.at(1.2))
    #expect(phase == [.resetGate, .show(.unanswered)])
  }

  @Test("not ready: the press does nothing and the lift hops with the record's reason")
  func notReady() {
    var handshake = PressHandshake()
    let down = handshake.handle(Fixture.micDown(ready: false, reason: .needsForeground), now: epoch)
    #expect(down == [.none])
    #expect(handshake.state == .unready(.needsForeground))
    let lift = handshake.handle(Fixture.tap, now: epoch)
    #expect(lift == [.hop(.needsForeground)])
    let unsaid = handshake.handle(Fixture.micDown(ready: false), now: epoch)
    #expect(unsaid == [.none])
    #expect(handshake.state == .unready(.sessionOff))
  }

  @Test("ready again, a press from unready goes out like any other")
  func readyAgain() {
    var handshake = PressHandshake()
    _ = handshake.handle(Fixture.micDown(ready: false, reason: .opening), now: epoch)
    let down = handshake.handle(Fixture.micDown(), now: epoch)
    #expect(down == [.armGate, .sendPress, .showConnecting])
    #expect(handshake.isIdle)
  }

  @Test("events that belong to no row change nothing")
  func ignored() {
    var handshake = PressHandshake()
    let sentAtRest = handshake.handle(.stopSent(id: UUID(), at: epoch), now: epoch)
    #expect(sentAtRest == [.none])
    let ackAtRest = handshake.handle(Fixture.ack(.started(UUID()), for: UUID()), now: epoch)
    #expect(ackAtRest == [.none])
    let phaseAtRest = handshake.handle(Fixture.published(.recording, dictation: UUID()), now: epoch)
    #expect(phaseAtRest == [.none])
    #expect(handshake.isIdle)
    let id = Fixture.pressed(&handshake)
    let downAgain = handshake.handle(Fixture.micDown(), now: epoch)
    #expect(downAgain == [.none])
    let sentAgain = handshake.handle(.pressSent(id: UUID(), at: epoch), now: epoch)
    #expect(sentAgain == [.none])
    #expect(handshake.pressID == id)
  }
}
