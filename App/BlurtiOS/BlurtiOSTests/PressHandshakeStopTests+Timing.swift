import Foundation
import Testing

@testable import BlurtiOSCore

/// The stop's clock at its exact instants: the retry, the deadline, and the
/// hold threshold a lift is measured against.
extension PressHandshakeStopTests {
  @Test("a stop's retry and deadline are instants: resent at the delay, given up at the deadline")
  func stopTimesAreExact() {
    // The stop goes out at the reference date, so each instant after it is exact in a Date.
    let sent = Date(timeIntervalSinceReferenceDate: 0)
    let pressedAt = sent.addingTimeInterval(-5)
    func stopping(_ handshake: inout PressHandshake) -> UUID {
      _ = handshake.handle(Fixture.micDown(), now: pressedAt)
      let press = UUID()
      _ = handshake.handle(.pressSent(id: press, at: pressedAt), now: pressedAt)
      _ = handshake.handle(Fixture.lift, now: pressedAt)
      let dictation = UUID()
      _ = handshake.handle(Fixture.ack(.started(dictation), for: press), now: pressedAt)
      _ = handshake.handle(Fixture.published(.recording, dictation: dictation), now: pressedAt)
      _ = handshake.handle(Fixture.micDown(phase: .recording, inFlight: dictation), now: sent)
      let stop = UUID()
      _ = handshake.handle(.stopSent(id: stop, at: sent), now: sent)
      return stop
    }
    var resending = PressHandshake()
    let stop = stopping(&resending)
    let retry = sent.addingTimeInterval(resending.retryDelay)
    #expect(resending.handle(.tick(now: retry), now: retry) == [.resendStop(id: stop)])
    var givingUp = PressHandshake()
    _ = stopping(&givingUp)
    let deadline = sent.addingTimeInterval(givingUp.stopDeadline)
    #expect(givingUp.handle(.tick(now: deadline), now: deadline) == [.resetGate])
  }

  @Test("a lift held exactly the hold threshold is a hold: it sends the release")
  func holdAtTheThreshold() {
    var handshake = PressHandshake()
    let dictation = Fixture.owned(&handshake, phase: .recording)
    let lift = handshake.handle(.micUp(heldFor: handshake.holdThreshold), now: Fixture.at(1))
    #expect(lift == [.sendRelease(dictation: dictation)])
  }
}
