import Foundation
import Testing

@testable import BlurtiOSCore

/// The hold: a lift at or past the threshold is the stop, sent the instant
/// the finger is off the key. The fixture is `PressHandshakeTests`'.
@Suite("Press handshake: the hold")
struct PressHandshakeHoldTests {
  typealias Fixture = HandshakeFixture
  let epoch = Fixture.epoch

  @Test("a hold's lift is the stop at once: owned, latched from busy, or unanswered; over words being made, nothing")
  func holdLifts() {
    var owned = PressHandshake()
    let dictation = Fixture.owned(&owned, phase: .recording)
    let lift = owned.handle(Fixture.holdLift, now: Fixture.at(2))
    #expect(lift == [.sendRelease(dictation: dictation)])
    var busy = PressHandshake()
    let theirs = Fixture.foreignViaBusy(&busy)
    let held = busy.handle(Fixture.holdLift, now: Fixture.at(1))
    #expect(held == [.sendRelease(dictation: theirs)])
    var pressing = PressHandshake()
    let id = Fixture.pressed(&pressing)
    let early = pressing.handle(Fixture.holdLift, now: Fixture.at(0.5))
    #expect(early == [.none])
    #expect(pressing.state == .pressing(id: id, sentAt: epoch, resent: false, stopWanted: true))
    let named = UUID()
    let answer = pressing.handle(Fixture.ack(.started(named), for: id), now: Fixture.at(0.6))
    #expect(answer == [.sendRelease(dictation: named)])
    var made = PressHandshake()
    _ = Fixture.owned(&made, phase: .processing)
    let nothing = made.handle(Fixture.holdLift, now: Fixture.at(3))
    #expect(nothing == [.none])
  }
}
