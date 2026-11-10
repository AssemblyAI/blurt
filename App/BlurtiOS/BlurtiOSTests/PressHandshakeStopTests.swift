import Foundation
import Testing

@testable import BlurtiOSCore

/// The stop half of the table: what a second finger down, a lift, a × and a
/// flip send once a press is out, and how the stop is answered. The fixture is `PressHandshakeTests`'.
@Suite("Press handshake: lifts, stops and the ×")
struct PressHandshakeStopTests {
  typealias Fixture = HandshakeFixture
  let epoch = Fixture.epoch

  @Test("a tap over our press waits for the answer; the next finger down releases at once, its lift nothing")
  func tapThenTap() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let lift = handshake.handle(Fixture.lift, now: Fixture.at(0.2))
    #expect(lift == [.none])
    #expect(handshake.state == .pressing(id: id, sentAt: epoch, resent: false, stopWanted: false))
    let dictation = UUID()
    _ = handshake.handle(Fixture.ack(.started(dictation), for: id), now: Fixture.at(0.3))
    let down = handshake.handle(Fixture.micDown(phase: .recording, inFlight: dictation), now: Fixture.at(2))
    #expect(down == [.armGate, .sendRelease(dictation: dictation)])
    #expect(handshake.isOwned)
    let up = handshake.handle(Fixture.lift, now: Fixture.at(2.1))
    #expect(up == [.none])
  }

  @Test("a finger down during connecting sends the release immediately")
  func stopWhileConnecting() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let dictation = UUID()
    _ = handshake.handle(Fixture.ack(.started(dictation), for: id), now: Fixture.at(0.2))
    #expect(handshake.state == .owned(dictation: dictation, phase: .connecting))
    let down = handshake.handle(Fixture.micDown(phase: .connecting, inFlight: dictation), now: Fixture.at(1.2))
    #expect(down == [.armGate, .sendRelease(dictation: dictation)])
    let stop = UUID()
    _ = handshake.handle(.stopSent(id: stop, at: Fixture.at(1.2)), now: Fixture.at(1.2))
    #expect(handshake.state == .stopping(id: stop, dictation: dictation, sentAt: Fixture.at(1.2), resent: false))
  }

  @Test("a second finger down at 1.1 s before the answer: started at 1.15 s, the release goes out at once")
  func secondPressWhilePressing() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let again = handshake.handle(Fixture.micDown(), now: Fixture.at(1.1))
    #expect(again == [.none])
    #expect(handshake.state == .pressing(id: id, sentAt: epoch, resent: false, stopWanted: true))
    let dictation = UUID()
    let answer = handshake.handle(Fixture.ack(.started(dictation), for: id), now: Fixture.at(1.15))
    #expect(answer == [.sendRelease(dictation: dictation)])
    #expect(handshake.isOwned)
  }

  @Test("a second finger down before the answer, answered by a phase or by busy, also releases at once")
  func secondPressThenPhase() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    _ = handshake.handle(Fixture.micDown(), now: Fixture.at(1.1))
    let dictation = UUID()
    let answer = handshake.handle(
      Fixture.published(.recording, answers: id, dictation: dictation), now: Fixture.at(1.15))
    #expect(answer == [.sendRelease(dictation: dictation)])
    var other = PressHandshake()
    let press = Fixture.pressed(&other)
    _ = other.handle(Fixture.micDown(), now: Fixture.at(1.1))
    let theirs = UUID()
    let busy = other.handle(Fixture.ack(.busy(theirs), for: press), now: Fixture.at(1.15))
    #expect(busy == [.sendRelease(dictation: theirs)])
    #expect(other.state == .foreign(dictation: theirs))
  }

  @Test("foreign via busy: the lift sends nothing, the next press releases; over a running one the press releases")
  func foreignPresses() {
    var tapped = PressHandshake()
    let theirs = Fixture.foreignViaBusy(&tapped)
    let lift = tapped.handle(Fixture.lift, now: Fixture.at(0.2))
    #expect(lift == [.none])
    #expect(tapped.state == .foreign(dictation: theirs))
    let down = tapped.handle(Fixture.micDown(phase: .recording, inFlight: theirs), now: Fixture.at(1))
    #expect(down == [.armGate, .sendRelease(dictation: theirs)])
    var running = PressHandshake()
    let dictation = UUID()
    let pressed = running.handle(Fixture.micDown(phase: .recording, inFlight: dictation), now: epoch)
    #expect(pressed == [.latch, .sendRelease(dictation: dictation)])
    #expect(running.state == .foreign(dictation: dictation))
    let up = running.handle(Fixture.lift, now: Fixture.at(0.2))
    #expect(up == [.none])
  }

  @Test("over the words being made nothing is sent: a finger down over owned(processing) buzzes, the lift nothing")
  func processingBuzzes() {
    var handshake = PressHandshake()
    let dictation = Fixture.owned(&handshake, phase: .processing)
    let down = handshake.handle(Fixture.micDown(phase: .processing, inFlight: dictation), now: Fixture.at(3))
    #expect(down == [.buzz])
    #expect(handshake.state == .owned(dictation: dictation, phase: .processing))
    let lift = handshake.handle(Fixture.lift, now: Fixture.at(3.1))
    #expect(lift == [.none])
    #expect(handshake.isOwned)
    var latched = PressHandshake()
    let theirs = Fixture.foreignViaLatch(&latched)
    _ = latched.handle(Fixture.published(.processing, dictation: theirs), now: Fixture.at(2))
    let made = latched.handle(Fixture.micDown(phase: .processing, inFlight: theirs), now: Fixture.at(3))
    #expect(made == [.buzz])
    #expect(latched.state == .foreign(dictation: theirs))
    let nothing = latched.handle(Fixture.lift, now: Fixture.at(3.1))
    #expect(nothing == [.none])
  }

  @Test("a stop is resent once at the retry delay and given up at its deadline, idle either way")
  func stopResendAndDeadline() {
    var handshake = PressHandshake()
    let (dictation, stop) = Fixture.stopping(&handshake)
    let early = handshake.handle(.tick(now: Fixture.at(5.5)), now: Fixture.at(5.5))
    #expect(early == [.none])
    let due = handshake.handle(.tick(now: Fixture.at(5.6)), now: Fixture.at(5.6))
    #expect(due == [.resendStop(id: stop)])
    #expect(handshake.state == .stopping(id: stop, dictation: dictation, sentAt: Fixture.at(5), resent: true))
    let late = handshake.handle(.tick(now: Fixture.at(6.2)), now: Fixture.at(6.2))
    #expect(late == [.resetGate])
    #expect(handshake.isIdle)
  }

  @Test("a stop is over on its ack or on a terminal phase for its dictation, not on another's notice")
  func stopAnswered() {
    var handshake = PressHandshake()
    let (dictation, stop) = Fixture.stopping(&handshake)
    let other = handshake.handle(Fixture.published(.pasted, dictation: UUID()), now: Fixture.at(5.1))
    #expect(other == [.none])
    #expect(handshake.stopID == stop)
    let ours = handshake.handle(Fixture.published(.pasted, dictation: dictation), now: Fixture.at(5.2))
    #expect(ours == [.resetGate])
    #expect(handshake.isIdle)
    var byAck = PressHandshake()
    let (second, secondStop) = Fixture.stopping(&byAck)
    let stopped = byAck.handle(Fixture.ack(.stopped(second), for: secondStop), now: Fixture.at(5.1))
    #expect(stopped == [.resetGate])
    #expect(byAck.isIdle)
  }

  @Test("× while owned sends cancel with the dictation's id and then stops")
  func cancelOwned() {
    var handshake = PressHandshake()
    let dictation = Fixture.owned(&handshake, phase: .recording)
    let cross = handshake.handle(.cancelTapped, now: Fixture.at(3))
    #expect(cross == [.sendCancel(dictation: dictation)])
    #expect(handshake.isOwned)
    let cancel = UUID()
    _ = handshake.handle(.cancelSent(id: cancel, at: Fixture.at(3)), now: Fixture.at(3))
    #expect(handshake.state == .stopping(id: cancel, dictation: dictation, sentAt: Fixture.at(3), resent: false))
    let cancelled = handshake.handle(Fixture.ack(.cancelled(dictation), for: cancel), now: Fixture.at(3.1))
    #expect(cancelled == [.resetGate])
    #expect(handshake.isIdle)
  }

  @Test("× over a latched dictation sends cancel with its id, however it was latched")
  func cancelForeign() {
    var latched = PressHandshake()
    let dictation = Fixture.foreignViaLatch(&latched)
    let cross = latched.handle(.cancelTapped, now: Fixture.at(1))
    #expect(cross == [.sendCancel(dictation: dictation)])
    var busy = PressHandshake()
    let theirs = Fixture.foreignViaBusy(&busy)
    let crossBusy = busy.handle(.cancelTapped, now: Fixture.at(1))
    #expect(crossBusy == [.sendCancel(dictation: theirs)])
    let cancel = UUID()
    _ = busy.handle(.cancelSent(id: cancel, at: Fixture.at(1)), now: Fixture.at(1))
    #expect(busy.state == .stopping(id: cancel, dictation: theirs, sentAt: Fixture.at(1), resent: false))
  }

  @Test("× before the answer sends a nameless cancel; the press's late answer names what is being stopped")
  func cancelWhilePressing() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let cross = handshake.handle(.cancelTapped, now: Fixture.at(0.1))
    #expect(cross == [.sendCancel(dictation: nil)])
    let cancel = UUID()
    _ = handshake.handle(.cancelSent(id: cancel, at: Fixture.at(0.1)), now: Fixture.at(0.1))
    #expect(handshake.state == .stopping(id: cancel, dictation: nil, sentAt: Fixture.at(0.1), resent: false))
    #expect(handshake.dictationID == nil)
    let dictation = UUID()
    let named = handshake.handle(Fixture.ack(.started(dictation), for: id), now: Fixture.at(0.2))
    #expect(named == [.none])
    #expect(handshake.state == .stopping(id: cancel, dictation: dictation, sentAt: Fixture.at(0.1), resent: false))
    let over = handshake.handle(Fixture.ack(.cancelled(dictation), for: cancel), now: Fixture.at(0.3))
    #expect(over == [.resetGate])
  }

  @Test("× over a release already out is still sent, and that cancel is the command awaited")
  func cancelWhileStopping() {
    var handshake = PressHandshake()
    let (dictation, _) = Fixture.stopping(&handshake)
    let cross = handshake.handle(.cancelTapped, now: Fixture.at(5.1))
    #expect(cross == [.sendCancel(dictation: dictation)])
    let cancel = UUID()
    _ = handshake.handle(.cancelSent(id: cancel, at: Fixture.at(5.1)), now: Fixture.at(5.1))
    #expect(handshake.state == .stopping(id: cancel, dictation: dictation, sentAt: Fixture.at(5.1), resent: false))
    let lift = handshake.handle(Fixture.lift, now: Fixture.at(5.2))
    #expect(lift == [.none])
  }

  @Test("× at rest or unready sends nothing")
  func cancelAtRest() {
    var handshake = PressHandshake()
    let rest = handshake.handle(.cancelTapped, now: epoch)
    #expect(rest == [.none])
    _ = handshake.handle(Fixture.micDown(ready: false, reason: .sessionOff), now: epoch)
    let unready = handshake.handle(.cancelTapped, now: epoch)
    #expect(unready == [.none])
  }

  @Test("a flip undoes the press only before anything is recorded: pressing or connecting; a recording keeps its words")
  func undoBeforeRecording() {
    var handshake = PressHandshake()
    #expect(!handshake.canUndoBeforeRecording)
    let rest = handshake.undoBeforeRecording(now: epoch)
    #expect(rest == [.none])
    _ = Fixture.pressed(&handshake)
    #expect(handshake.canUndoBeforeRecording)
    let fresh = handshake.undoBeforeRecording(now: Fixture.at(0.1))
    #expect(fresh == [.sendCancel(dictation: nil)])
    var connecting = PressHandshake()
    let dictation = Fixture.owned(&connecting)
    #expect(connecting.canUndoBeforeRecording)
    let undone = connecting.undoBeforeRecording(now: Fixture.at(0.2))
    #expect(undone == [.sendCancel(dictation: dictation)])
    var recording = PressHandshake()
    _ = Fixture.owned(&recording, phase: .recording)
    #expect(!recording.canUndoBeforeRecording)
    let kept = recording.undoBeforeRecording(now: Fixture.at(2))
    #expect(kept == [.none])
    #expect(recording.isOwned)
    var latched = PressHandshake()
    _ = Fixture.foreignViaLatch(&latched)
    #expect(!latched.canUndoBeforeRecording)
    let theirs = latched.undoBeforeRecording(now: Fixture.at(1))
    #expect(theirs == [.none])
    _ = latched.handle(Fixture.lift, now: Fixture.at(1))
    _ = latched.handle(.stopSent(id: UUID(), at: Fixture.at(1)), now: Fixture.at(1))
    #expect(!latched.canUndoBeforeRecording)
  }

  @Test("the phases drive an owned dictation's picture, and its end frees the gate")
  func ownedFollowsPhases() {
    var handshake = PressHandshake()
    let dictation = Fixture.owned(&handshake)
    let recording = handshake.handle(Fixture.published(.recording, dictation: dictation), now: Fixture.at(1))
    #expect(recording == [.none])
    #expect(handshake.state == .owned(dictation: dictation, phase: .recording))
    let previous = handshake.handle(Fixture.published(.pasted, dictation: UUID()), now: Fixture.at(1.1))
    #expect(previous == [.none])
    #expect(handshake.isOwned)
    let unnamed = handshake.handle(Fixture.published(.processing), now: Fixture.at(2))
    #expect(unnamed == [.none])
    #expect(handshake.state == .owned(dictation: dictation, phase: .processing))
    let over = handshake.handle(Fixture.published(.pasted, dictation: dictation), now: Fixture.at(3))
    #expect(over == [.resetGate])
    #expect(handshake.isIdle)
  }
}
