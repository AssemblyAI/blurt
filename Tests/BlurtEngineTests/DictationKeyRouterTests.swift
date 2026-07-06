import Testing

@testable import BlurtEngine

/// The router's two jobs on top of `DictationKeyGate` (whose tap/hold semantics
/// have their own suites): only the bound keycode's flag *edges* reach the gate
/// — `flagsChanged` deliveries re-report the bit whether or not it changed, so
/// a repeat must not double-fire — and reset/rebind report whether they
/// discarded a live recording the host has to cancel upstream.
@Suite("DictationKeyRouter")
struct DictationKeyRouterTests {
  private let trigger = TriggerKey.rightCommand.keyCode
  private let otherModifier = TriggerKey.rightOption.keyCode

  private func downEvent(_ keyCode: Int) -> DictationKeyRouter.Event {
    .flagsChanged(keyCode: keyCode, triggerFlagIsOn: true)
  }

  private func upEvent(_ keyCode: Int) -> DictationKeyRouter.Event {
    .flagsChanged(keyCode: keyCode, triggerFlagIsOn: false)
  }

  @Test("a held press is start → stop")
  func holdIsStartStop() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
  }

  @Test("a repeated down-state delivery doesn't re-fire the gate")
  func repeatedDownStateIsDeduped() {
    // While the trigger is held, another flags delivery can re-report its bit
    // still set; re-arming the gate on it would corrupt the tap/hold timing.
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(downEvent(trigger), at: .milliseconds(50)) == .none)
    // The eventual release still stops the (single) dictation.
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
  }

  @Test("an up-state delivery with no tracked down is ignored")
  func upWithoutDownIsIgnored() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(upEvent(trigger), at: .zero) == .none)
  }

  @Test("flag changes reported for another keycode never reach the gate")
  func otherKeycodeFlagsAreIgnored() {
    // E.g. right ⌥ going down while right ⌘ is bound: the delivery's flags may
    // even carry the trigger's bit, but the event isn't about the bound key.
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(downEvent(otherModifier), at: .zero) == .none)
    #expect(router.handle(upEvent(otherModifier), at: .seconds(2)) == .none)
  }

  @Test("another key over a fresh press is a combo and cancels")
  func comboCancelsFreshCapture() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(.keyDown(keyCode: 8), at: .milliseconds(100)) == .cancel)  // ⌘C
  }

  @Test("the trigger's own keyDown is not a combo")
  func triggerKeyDownIsNotACombo() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(.keyDown(keyCode: trigger), at: .milliseconds(100)) == .none)
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
  }

  @Test("a short tap latches; the next tap stops")
  func tapToToggle() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .none)  // latched
    #expect(router.handle(downEvent(trigger), at: .seconds(5)) == .none)
    #expect(router.handle(upEvent(trigger), at: .seconds(5) + .milliseconds(200)) == .stop)
  }

  @Test("reset while idle reports nothing discarded")
  func resetWhileIdle() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(!router.reset())
  }

  @Test("reset mid-recording reports the discarded recording")
  func resetMidRecordingReportsDiscard() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.reset())
    // The tracker cleared too: the stale key-up is ignored, a new press starts.
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .none)
    #expect(router.handle(downEvent(trigger), at: .seconds(3)) == .start)
  }

  @Test("reset over a latched recording reports the discarded recording")
  func resetOverLatchedReportsDiscard() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .none)  // latched
    #expect(router.reset())
  }

  @Test("rebind mid-recording discards it and switches keycodes")
  func rebindMidRecording() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    // Rebinding means the old key's up-event can never match — the caller must
    // cancel the capture rather than let the auto-release cap paste it.
    #expect(router.rebind(triggerKeyCode: otherModifier))
    #expect(router.triggerKeyCode == otherModifier)
    // The old key is now irrelevant; the new one drives dictation.
    #expect(router.handle(downEvent(trigger), at: .seconds(1)) == .none)
    #expect(router.handle(downEvent(otherModifier), at: .seconds(2)) == .start)
  }

  @Test("rebind while idle reports nothing discarded")
  func rebindWhileIdle() {
    var router = DictationKeyRouter(triggerKeyCode: trigger)
    #expect(!router.rebind(triggerKeyCode: otherModifier))
  }
}
