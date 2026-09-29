import CoreGraphics
import Testing

@testable import BlurtiOS

@Suite("Keyboard interaction rules")
struct KeyboardInteractionTests {
  @Test("a swipe flips the panel past 48 pt sideways and 1.5× the vertical, the way the finger went")
  func flip() {
    #expect(KeyboardInteraction.flip(CGSize(width: 47, height: 0)) == nil)
    #expect(KeyboardInteraction.flip(CGSize(width: 49, height: 0)) == .towardsTrailing)
    #expect(KeyboardInteraction.flip(CGSize(width: -49, height: 0)) == .towardsLeading)
    #expect(KeyboardInteraction.flip(CGSize(width: 49, height: 40)) == nil)
    #expect(KeyboardInteraction.flip(CGSize(width: 60, height: 39)) == .towardsTrailing)
  }

  @Test("a key acts only under 12 pt of travel; the mic cancels past 24")
  func travel() {
    #expect(KeyboardInteraction.isTap(CGSize(width: 11.9, height: 11.9)))
    #expect(!KeyboardInteraction.isTap(CGSize(width: 12, height: 0)))
    #expect(!KeyboardInteraction.isTap(CGSize(width: 0, height: -12)))
    #expect(!KeyboardInteraction.micTravelled(CGSize(width: 24, height: 24)))
    #expect(KeyboardInteraction.micTravelled(CGSize(width: 24.1, height: 0)))
    #expect(KeyboardInteraction.micTravelled(CGSize(width: 0, height: -24.1)))
  }

  // `#expect` captures its expression immutably, so each mutating step lands
  // in a local first.
  @Test("a quick tap presses and releases together")
  func quickTap() {
    var press = MicPressSequencer()
    let armed = press.began()
    #expect(armed)
    let armedAgain = press.began()
    #expect(!armedAgain)
    let outcome = press.ended(travelled: false)
    #expect(outcome == .tap(needsDown: true))
    #expect(press == MicPressSequencer())
  }

  @Test("a hold presses when the timer fires and releases on the lift")
  func hold() {
    var press = MicPressSequencer()
    _ = press.began()
    let fired = press.delayFired()
    #expect(fired)
    let firedAgain = press.delayFired()
    #expect(!firedAgain)
    let outcome = press.ended(travelled: false)
    #expect(outcome == .tap(needsDown: false))
  }

  @Test("a swipe before the timer fires cancels it and does nothing")
  func swipeBeforePress() {
    var press = MicPressSequencer()
    _ = press.began()
    let stayed = press.moved(travelled: false)
    #expect(!stayed)
    let cancelled = press.moved(travelled: true)
    #expect(cancelled)
    let cancelledAgain = press.moved(travelled: true)
    #expect(!cancelledAgain)
    let fired = press.delayFired()
    #expect(!fired)
    let outcome = press.ended(travelled: true)
    #expect(outcome == .nothing)
  }

  @Test("a swipe after the press went out undoes it")
  func swipeAfterPress() {
    var press = MicPressSequencer()
    _ = press.began()
    _ = press.delayFired()
    let cancelled = press.moved(travelled: true)
    #expect(!cancelled)
    let outcome = press.ended(travelled: true)
    #expect(outcome == .cancelSentPress)
  }
}
