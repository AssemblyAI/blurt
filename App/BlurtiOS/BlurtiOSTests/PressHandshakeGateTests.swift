import Foundation
import Testing

@testable import BlurtiOSCore

/// The gate and the record: which touches the gate gets, what a latch holds,
/// and what the readiness record ends. The fixture is `PressHandshakeTests`'.
@Suite("Press handshake: the gate, the latch and the record")
struct PressHandshakeGateTests {
  typealias Fixture = HandshakeFixture
  let epoch = Fixture.epoch

  @Test("a tap from rest arms the gate; answered before the lift, the lift sends nothing and the next tap stops")
  func tapAnsweredBeforeLift() {
    var handshake = PressHandshake()
    let down = handshake.handle(Fixture.micDown(), now: epoch)
    #expect(down == [.armGate, .sendPress, .showConnecting])
    let id = UUID()
    _ = handshake.handle(.pressSent(id: id, at: epoch), now: epoch)
    let dictation = UUID()
    _ = handshake.handle(Fixture.ack(.started(dictation), for: id), now: Fixture.at(0.1))
    let lift = handshake.handle(Fixture.tap, now: Fixture.at(0.2))
    #expect(lift == [.none])
    #expect(handshake.state == .owned(dictation: dictation, phase: .connecting))
    _ = handshake.handle(Fixture.published(.recording, dictation: dictation), now: Fixture.at(0.5))
    let again = handshake.handle(Fixture.micDown(phase: .recording, inFlight: dictation), now: Fixture.at(2))
    #expect(again == [.armGate])
    let stop = handshake.handle(Fixture.liftOverLatch, now: Fixture.at(2.1))
    #expect(stop == [.sendRelease(dictation: dictation)])
  }

  @Test("the gate is never armed for an unready press, a buzz, or a press or stop still out")
  func gateNeverArmed() {
    var unready = PressHandshake()
    let refused = unready.handle(Fixture.micDown(ready: false, reason: .opening), now: epoch)
    #expect(refused == [.none])
    var busy = PressHandshake()
    let words = busy.handle(Fixture.micDown(phase: .processing, inFlight: UUID()), now: epoch)
    #expect(words == [.buzz])
    let unnamed = busy.handle(Fixture.micDown(phase: .recording), now: epoch)
    #expect(unnamed == [.buzz])
    #expect(busy.isIdle)
    var pressing = PressHandshake()
    _ = Fixture.pressed(&pressing)
    let again = pressing.handle(Fixture.micDown(), now: Fixture.at(0.1))
    #expect(again == [.none])
    var stopping = PressHandshake()
    let dictation = Fixture.owned(&stopping, phase: .recording)
    _ = stopping.handle(Fixture.liftOverLatch, now: Fixture.at(5))
    _ = stopping.handle(.stopSent(id: UUID(), at: Fixture.at(5)), now: Fixture.at(5))
    let over = stopping.handle(Fixture.micDown(phase: .recording, inFlight: dictation), now: Fixture.at(5.1))
    #expect(over == [.none])
    var processing = PressHandshake()
    let ours = Fixture.owned(&processing, phase: .processing)
    let made = processing.handle(Fixture.micDown(phase: .processing, inFlight: ours), now: Fixture.at(3))
    #expect(made == [.buzz])
  }

  @Test("a foreign dictation latches and one lift stops it with its id")
  func foreign() {
    var handshake = PressHandshake()
    let dictation = UUID()
    let down = handshake.handle(Fixture.micDown(phase: .recording, inFlight: dictation), now: epoch)
    #expect(down == [.latch])
    #expect(handshake.state == .foreign(dictation: dictation, liftStops: true))
    let lift = handshake.handle(Fixture.liftOverLatch, now: epoch)
    #expect(lift == [.sendRelease(dictation: dictation)])
    let stop = UUID()
    _ = handshake.handle(.stopSent(id: stop, at: epoch), now: epoch)
    #expect(handshake.state == .stopping(id: stop, dictation: dictation, sentAt: epoch, resent: false))
    #expect(handshake.stopID == stop && handshake.dictationID == dictation)
    let stopped = handshake.handle(Fixture.ack(.stopped(dictation), for: stop), now: epoch)
    #expect(stopped == [.resetGate])
    #expect(handshake.isIdle)
  }

  @Test("a foreign dictation's end frees the latch; another one running takes its place")
  func foreignEnds() {
    var handshake = PressHandshake()
    let first = UUID()
    _ = handshake.handle(Fixture.micDown(phase: .connecting, inFlight: first), now: epoch)
    let second = UUID()
    let replaced = handshake.handle(Fixture.published(.recording, dictation: second), now: epoch)
    #expect(replaced == [.none])
    #expect(handshake.state == .foreign(dictation: second, liftStops: true))
    let over = handshake.handle(Fixture.published(.pasted, dictation: second), now: epoch)
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
    #expect(fresh == [.resetGate, .armGate, .sendPress, .showConnecting])
    #expect(handshake.isIdle)
    var replaced = PressHandshake()
    _ = Fixture.owned(&replaced, phase: .recording)
    let theirs = UUID()
    let down = replaced.handle(Fixture.micDown(phase: .recording, inFlight: theirs), now: Fixture.at(4))
    #expect(down == [.armGate])
    #expect(replaced.state == .foreign(dictation: theirs, liftStops: true))
    #expect(dictation != theirs)
  }

  @Test("a finger down over a dictation that ended unseen takes no press from a closed or lapsed window: the lift hops")
  func endedUnseenNotReady() {
    var owned = PressHandshake()
    _ = Fixture.owned(&owned, phase: .recording)
    let closed = owned.handle(Fixture.micDown(ready: false, reason: .sessionOff, phase: .idle), now: Fixture.at(5))
    #expect(closed == [.resetGate, .show(.sessionOff)])
    #expect(owned.state == .unready(.sessionOff))
    let lift = owned.handle(Fixture.tap, now: Fixture.at(5.1))
    #expect(lift == [.hop(.sessionOff)])
    var latched = PressHandshake()
    _ = Fixture.foreignViaLatch(&latched)
    let lapsed = latched.handle(
      Fixture.micDown(ready: false, reason: .suspended, phase: .pasted), now: Fixture.at(20))
    #expect(lapsed == [.resetGate, .show(.suspended)])
    #expect(latched.unreadyReason == .suspended)
    var unsaid = PressHandshake()
    _ = Fixture.owned(&unsaid, phase: .recording)
    let silent = unsaid.handle(Fixture.micDown(ready: false, phase: .error), now: Fixture.at(5))
    #expect(silent == [.resetGate, .show(.sessionOff)])
  }

  @Test("a record merely not ready while owned keeps owned: the app is alive to end the dictation")
  func notReadyWhileOwned() {
    var handshake = PressHandshake()
    let dictation = Fixture.owned(&handshake, phase: .recording)
    let interrupted = handshake.handle(
      .stateChanged(Fixture.record(.interrupted, micLive: false)), now: Fixture.at(1))
    #expect(interrupted == [.none])
    #expect(handshake.state == .owned(dictation: dictation, phase: .recording))
    let closed = handshake.handle(
      .stateChanged(Fixture.record(.closed, micLive: false, reason: .sessionOff)), now: Fixture.at(2))
    #expect(closed == [.none])
    #expect(handshake.isOwned)
  }

  @Test("a lapsed lease, or no record, ends trust in the phase: owned, latched or pressing → suspended, gate reset")
  func lapsedLeaseEndsTrust() {
    var owned = PressHandshake()
    _ = Fixture.owned(&owned, phase: .recording)
    let gone = owned.handle(.stateChanged(nil), now: Fixture.at(1))
    #expect(gone == [.resetGate, .show(.suspended)])
    #expect(owned.state == .unready(.suspended))
    var lapsed = PressHandshake()
    _ = Fixture.owned(&lapsed, phase: .recording)
    let stale = lapsed.handle(.stateChanged(Fixture.record(.open)), now: Fixture.at(ListeningState.lease))
    #expect(stale == [.resetGate, .show(.suspended)])
    #expect(lapsed.state == .unready(.suspended))
    var pressing = PressHandshake()
    _ = Fixture.pressed(&pressing)
    let dropped = pressing.handle(.stateChanged(nil), now: Fixture.at(0.1))
    #expect(dropped == [.resetGate, .show(.suspended)])
    var latched = PressHandshake()
    _ = Fixture.foreignViaLatch(&latched)
    let left = latched.handle(.stateChanged(nil), now: Fixture.at(0.1))
    #expect(left == [.resetGate, .show(.suspended)])
    #expect(latched.state == .unready(.suspended))
    let lift = latched.handle(Fixture.liftOverLatch, now: Fixture.at(0.2))
    #expect(lift == [.hop(.suspended)])
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
    _ = Fixture.foreignViaLatch(&latched)
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
    let again = handshake.handle(.stateChanged(Fixture.record(.opening, micLive: false)), now: epoch)
    #expect(again == [.none], "the heartbeat's repeat of the record is not another refusal")
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
    let dead = stopping.handle(.stateChanged(nil), now: Fixture.at(5.2))
    #expect(dead == [.none])
    #expect(stopping.stopID == stop)
  }
}
