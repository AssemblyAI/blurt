import Foundation
import Testing

@testable import BlurtiOSCore

/// The second half of the table: what a lift, a ×, the phases and the
/// readiness record do once a press is out. The fixture is `PressHandshakeTests`'.
@Suite("Press handshake: lifts, stops and the record")
struct PressHandshakeStopTests {
  typealias Fixture = HandshakeFixture
  let epoch = Fixture.epoch

  @Test("a tap over our press waits for the answer; the next tap's lift releases the dictation")
  func tapThenTap() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let lift = handshake.handle(Fixture.tap, now: Fixture.at(0.2))
    #expect(lift == [.none])
    #expect(handshake.state == .pressing(id: id, sentAt: epoch, resent: false, stopWanted: false))
    let dictation = UUID()
    _ = handshake.handle(Fixture.ack(.started(dictation), for: id), now: Fixture.at(0.3))
    let down = handshake.handle(Fixture.micDown(phase: .recording, inFlight: dictation), now: Fixture.at(2))
    #expect(down == [.none])
    #expect(handshake.isOwned)
    let stop = handshake.handle(Fixture.liftOverLatch, now: Fixture.at(2.1))
    #expect(stop == [.sendRelease(dictation: dictation)])
  }

  @Test("stop during connecting sends release immediately")
  func stopWhileConnecting() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let dictation = UUID()
    _ = handshake.handle(Fixture.ack(.started(dictation), for: id), now: Fixture.at(0.2))
    #expect(handshake.state == .owned(dictation: dictation, phase: .connecting))
    let lift = handshake.handle(Fixture.hold, now: Fixture.at(1.2))
    #expect(lift == [.sendRelease(dictation: dictation)])
    let stop = UUID()
    _ = handshake.handle(.stopSent(id: stop, at: Fixture.at(1.2)), now: Fixture.at(1.2))
    #expect(handshake.state == .stopping(id: stop, dictation: dictation, sentAt: Fixture.at(1.2), resent: false))
  }

  @Test("a hold lifted before the answer: the release waits for the id, then goes at once")
  func holdLiftedWhilePressing() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    let lift = handshake.handle(Fixture.hold, now: Fixture.at(1.1))
    #expect(lift == [.none])
    #expect(handshake.state == .pressing(id: id, sentAt: epoch, resent: false, stopWanted: true))
    let dictation = UUID()
    let answer = handshake.handle(Fixture.ack(.started(dictation), for: id), now: Fixture.at(1.15))
    #expect(answer == [.sendRelease(dictation: dictation)])
    #expect(handshake.isOwned)
  }

  @Test("a hold lifted before the answer, answered by a phase or by busy, also releases at once")
  func holdLiftedThenPhase() {
    var handshake = PressHandshake()
    let id = Fixture.pressed(&handshake)
    _ = handshake.handle(Fixture.hold, now: Fixture.at(1.1))
    let dictation = UUID()
    let answer = handshake.handle(
      Fixture.published(.recording, answers: id, dictation: dictation), now: Fixture.at(1.15))
    #expect(answer == [.sendRelease(dictation: dictation)])
    var other = PressHandshake()
    let press = Fixture.pressed(&other)
    _ = other.handle(Fixture.hold, now: Fixture.at(1.1))
    let theirs = UUID()
    let busy = other.handle(Fixture.ack(.busy(theirs), for: press), now: Fixture.at(1.15))
    #expect(busy == [.sendRelease(dictation: theirs)])
    #expect(other.state == .foreign(dictation: theirs))
  }

  @Test("a stop is resent once at the retry delay and given up at its deadline, idle either way")
  func stopResendAndDeadline() {
    var handshake = PressHandshake()
    let dictation = Fixture.owned(&handshake, phase: .recording)
    _ = handshake.handle(Fixture.liftOverLatch, now: Fixture.at(5))
    let stop = UUID()
    _ = handshake.handle(.stopSent(id: stop, at: Fixture.at(5)), now: Fixture.at(5))
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
    let dictation = Fixture.owned(&handshake, phase: .recording)
    _ = handshake.handle(Fixture.liftOverLatch, now: Fixture.at(5))
    let stop = UUID()
    _ = handshake.handle(.stopSent(id: stop, at: Fixture.at(5)), now: Fixture.at(5))
    let other = handshake.handle(Fixture.published(.pasted, dictation: UUID()), now: Fixture.at(5.1))
    #expect(other == [.none])
    #expect(handshake.stopID == stop)
    let ours = handshake.handle(Fixture.published(.pasted, dictation: dictation), now: Fixture.at(5.2))
    #expect(ours == [.resetGate])
    #expect(handshake.isIdle)
    var byAck = PressHandshake()
    let second = Fixture.owned(&byAck, phase: .recording)
    _ = byAck.handle(Fixture.liftOverLatch, now: Fixture.at(5))
    _ = byAck.handle(.stopSent(id: stop, at: Fixture.at(5)), now: Fixture.at(5))
    let stopped = byAck.handle(Fixture.ack(.stopped(second), for: stop), now: Fixture.at(5.1))
    #expect(stopped == [.resetGate])
    #expect(byAck.isIdle)
  }

  @Test("× while owned or latched sends cancel with the dictation's id and then stops")
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
    let dictation = Fixture.owned(&handshake, phase: .recording)
    _ = handshake.handle(Fixture.liftOverLatch, now: Fixture.at(5))
    let stop = UUID()
    _ = handshake.handle(.stopSent(id: stop, at: Fixture.at(5)), now: Fixture.at(5))
    let cross = handshake.handle(.cancelTapped, now: Fixture.at(5.1))
    #expect(cross == [.sendCancel(dictation: dictation)])
    let cancel = UUID()
    _ = handshake.handle(.cancelSent(id: cancel, at: Fixture.at(5.1)), now: Fixture.at(5.1))
    #expect(handshake.state == .stopping(id: cancel, dictation: dictation, sentAt: Fixture.at(5.1), resent: false))
    let lift = handshake.handle(Fixture.tap, now: Fixture.at(5.2))
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

  @Test("a finger down over an owned dictation that ended unseen clears the gate and presses afresh")
  func ownedEndedUnseen() {
    var handshake = PressHandshake()
    let dictation = Fixture.owned(&handshake, phase: .recording)
    let lingering = handshake.handle(Fixture.micDown(phase: .pasted, inFlight: UUID()), now: Fixture.at(4))
    #expect(lingering == [.none])
    #expect(handshake.isOwned)
    let fresh = handshake.handle(Fixture.micDown(phase: .idle), now: Fixture.at(5))
    #expect(fresh == [.resetGate, .sendPress, .showConnecting])
    #expect(handshake.isIdle)
    var replaced = PressHandshake()
    _ = Fixture.owned(&replaced, phase: .recording)
    let theirs = UUID()
    let down = replaced.handle(Fixture.micDown(phase: .recording, inFlight: theirs), now: Fixture.at(4))
    #expect(down == [.none])
    #expect(replaced.state == .foreign(dictation: theirs))
    #expect(dictation != theirs)
  }

  @Test("stateChanged interrupted while owned-and-recording keeps owned")
  func interruptedWhileOwned() {
    var handshake = PressHandshake()
    let dictation = Fixture.owned(&handshake, phase: .recording)
    let interrupted = handshake.handle(
      .stateChanged(Fixture.record(.interrupted, micLive: false)), now: epoch)
    #expect(interrupted == [.none])
    #expect(handshake.state == .owned(dictation: dictation, phase: .recording))
    let gone = handshake.handle(.stateChanged(nil), now: epoch)
    #expect(gone == [.none])
    #expect(handshake.isOwned)
  }

  @Test("stateChanged not ready while pressing or latched gives up with the record's reason")
  func notReadyWhilePressing() {
    var handshake = PressHandshake()
    _ = Fixture.pressed(&handshake)
    let closed = handshake.handle(
      .stateChanged(Fixture.record(.closed, micLive: false, reason: .sessionOff)), now: epoch)
    #expect(closed == [.resetGate, .show(.sessionOff)])
    #expect(handshake.state == .unready(.sessionOff))
    var latched = PressHandshake()
    _ = latched.handle(Fixture.micDown(phase: .recording, inFlight: UUID()), now: epoch)
    let lapsed = latched.handle(.stateChanged(Fixture.record(.open)), now: Fixture.at(ListeningState.lease + 1))
    #expect(lapsed == [.resetGate, .show(.suspended)])
    #expect(latched.state == .unready(.suspended))
  }

  @Test("stateChanged at rest: not ready shows the reason, ready again is idle; a stop out keeps waiting")
  func stateAtRest() {
    var handshake = PressHandshake()
    let closed = handshake.handle(.stateChanged(Fixture.record(.opening, micLive: false)), now: epoch)
    #expect(closed == [.show(.opening)])
    #expect(handshake.state == .unready(.opening))
    let gone = handshake.handle(.stateChanged(nil), now: epoch)
    #expect(gone == [.show(.sessionOff)])
    let open = handshake.handle(.stateChanged(Fixture.record(.open)), now: epoch)
    #expect(open == [.none])
    #expect(handshake.isIdle)
    let still = handshake.handle(.stateChanged(Fixture.record(.open)), now: epoch)
    #expect(still == [.none])
    var stopping = PressHandshake()
    let dictation = Fixture.owned(&stopping, phase: .recording)
    _ = stopping.handle(Fixture.liftOverLatch, now: Fixture.at(5))
    let stop = UUID()
    _ = stopping.handle(.stopSent(id: stop, at: Fixture.at(5)), now: Fixture.at(5))
    let kept = stopping.handle(.stateChanged(Fixture.record(.closing, micLive: false)), now: Fixture.at(5.1))
    #expect(kept == [.none])
    #expect(stopping.state == .stopping(id: stop, dictation: dictation, sentAt: Fixture.at(5), resent: false))
  }
}
