import Testing

@testable import BlurtEngine

/// The router's three jobs on top of `DictationKeyGate` (whose tap/hold semantics
/// have their own suites): only the bound trigger's genuine down/up *edges* reach
/// the gate — `flagsChanged` deliveries re-report the bit whether or not it
/// changed, and a held key can re-report its down state, so a repeat must not
/// double-fire — reset/rebind report whether they discarded a live recording the
/// host has to cancel upstream, and dropped-event recovery decides whether a
/// disabled-then-re-enabled tap keeps the gate's state.
@Suite("DictationKeyRouter")
struct DictationKeyRouterTests {
  private let trigger = TriggerKey.rightCommand
  private let otherModifier = TriggerKey.rightOption

  private func downEvent(_ key: TriggerKey) -> DictationKeyRouter.Event {
    .flagsChanged(keyCode: key.keyCode, triggerFlagIsOn: true)
  }

  private func upEvent(_ key: TriggerKey) -> DictationKeyRouter.Event {
    .flagsChanged(keyCode: key.keyCode, triggerFlagIsOn: false)
  }

  private func modifierRouter() -> DictationKeyRouter {
    DictationKeyRouter(binding: .modifier(trigger))
  }

  @Test("a held press is start → stop")
  func holdIsStartStop() {
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
  }

  @Test("a repeated down-state delivery doesn't re-fire the gate")
  func repeatedDownStateIsDeduped() {
    // While the trigger is held, another flags delivery can re-report its bit
    // still set; re-arming the gate on it would corrupt the tap/hold timing.
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(downEvent(trigger), at: .milliseconds(50)) == .none)
    // The eventual release still stops the (single) dictation.
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
  }

  @Test("an up-state delivery with no tracked down is ignored")
  func upWithoutDownIsIgnored() {
    var router = modifierRouter()
    #expect(router.handle(upEvent(trigger), at: .zero) == .none)
  }

  @Test("flag changes reported for another keycode never reach the gate")
  func otherKeycodeFlagsAreIgnored() {
    // E.g. right ⌥ going down while right ⌘ is bound: the delivery's flags may
    // even carry the trigger's bit, but the event isn't about the bound key.
    var router = modifierRouter()
    #expect(router.handle(downEvent(otherModifier), at: .zero) == .none)
    #expect(router.handle(upEvent(otherModifier), at: .seconds(2)) == .none)
  }

  @Test("another key over a fresh press is a combo and cancels")
  func comboCancelsFreshCapture() {
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(.keyDown(keyCode: 8), at: .milliseconds(100)) == .cancel)  // ⌘C
  }

  @Test("the trigger's own keyDown is not a combo")
  func triggerKeyDownIsNotACombo() {
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(.keyDown(keyCode: trigger.keyCode), at: .milliseconds(100)) == .none)
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
  }

  @Test("mouse events never reach a modifier binding's gate")
  func modifierBindingIgnoresOtherFamilies() {
    // The tap's mask covers every family any binding might need, so a modifier
    // binding sees extra-button clicks too — which may neither drive nor cancel
    // its gate (only a keyDown marks a combo).
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(.mouseDown(button: 3), at: .milliseconds(60)) == .none)
    #expect(router.handle(.mouseUp(button: 3), at: .milliseconds(70)) == .none)
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
  }

  @Test("a short tap latches; the next tap stops")
  func tapToToggle() {
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .none)  // latched
    #expect(router.handle(downEvent(trigger), at: .seconds(5)) == .none)
    #expect(router.handle(upEvent(trigger), at: .seconds(5) + .milliseconds(200)) == .stop)
  }

  // Note: `reset()`/`rebind(_:)` results are hoisted into locals below because
  // #expect can't invoke a mutating method directly (its expansion captures the
  // receiver in an immutable closure).

  @Test("reset while idle reports nothing discarded")
  func resetWhileIdle() {
    var router = modifierRouter()
    let discarded = router.reset()
    #expect(!discarded)
  }

  @Test("reset mid-recording reports the discarded recording")
  func resetMidRecordingReportsDiscard() {
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    let discarded = router.reset()
    #expect(discarded)
    // The tracker cleared too: the stale key-up is ignored, a new press starts.
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .none)
    #expect(router.handle(downEvent(trigger), at: .seconds(3)) == .start)
  }

  @Test("reset over a latched recording reports the discarded recording")
  func resetOverLatchedReportsDiscard() {
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .none)  // latched
    let discarded = router.reset()
    #expect(discarded)
  }

  @Test("a latch left behind by a keyless dictation end doesn't swallow the next press")
  func resetClearsLatchSoNextPressStarts() {
    // The bug this pins: when a dictation ends WITHOUT a key event — the
    // auto-release cap fires, or the press is refused/failed — the gate stays
    // `.latched`. A latched `modifierDown` returns `.none` and the `modifierUp`
    // after it returns `.stop`, which no-ops on an already-terminal session, so
    // the user's whole next press does nothing. `DictationKeyTap`'s
    // `syncAfterTerminalPhase()` calls `reset()` to clear it; this pins that a
    // reset genuinely restores the next press.
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .none)  // latched

    // Without the reset, this next tap is swallowed — the exact dead press.
    var swallowed = router
    #expect(swallowed.handle(downEvent(trigger), at: .seconds(5)) == .none)

    router.reset()
    #expect(router.handle(downEvent(trigger), at: .seconds(5)) == .start)
  }

  @Test("reset after a keyless end ignores a stale key-up, then starts cleanly")
  func resetWhileHeldThenReleaseIsInert() {
    // The auto-release/failed-press case where the trigger is still physically
    // held when the phase goes terminal. `syncAfterTerminalPhase` resets anyway
    // (the dictation is over), which clears the down tracker — so the release
    // that follows must route to `.none` rather than emitting a spurious `.stop`,
    // and the press after that must start normally.
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)

    router.reset()  // terminal phase arrived while the key is still down

    #expect(router.handle(upEvent(trigger), at: .milliseconds(300)) == .none)
    #expect(router.handle(downEvent(trigger), at: .seconds(2)) == .start)
  }

  @Test("rebind mid-recording discards it and switches bindings")
  func rebindMidRecording() {
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    // Rebinding means the old key's up-event can never match — the caller must
    // cancel the capture rather than let the auto-release cap paste it.
    let discarded = router.rebind(binding: .modifier(otherModifier))
    #expect(discarded)
    #expect(router.binding == .modifier(otherModifier))
    // The old key is now irrelevant; the new one drives dictation.
    #expect(router.handle(downEvent(trigger), at: .seconds(1)) == .none)
    #expect(router.handle(downEvent(otherModifier), at: .seconds(2)) == .start)
  }

  @Test("rebind while idle reports nothing discarded")
  func rebindWhileIdle() {
    var router = modifierRouter()
    let discarded = router.rebind(binding: .modifier(otherModifier))
    #expect(!discarded)
  }

  @Test("dropped-event recovery keeps a recording whose trigger is still held")
  func recoveryWhileStillHeldKeepsTheRecording() {
    // The tap was disabled mid-sentence. The key-up hasn't happened yet, so it is
    // still coming and the gate is coherent — resetting here would throw away
    // speech the user is in the middle of.
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)

    // Bound to a local rather than asserted inline: `#expect` rewrites a bare
    // function call into a closure taking an *immutable* receiver, so a `mutating`
    // method can't be called inside it — same reason the rebind cases above bind
    // `discarded` first.
    let discarded = router.recoverFromDroppedEvents(triggerStillHeld: true)
    #expect(!discarded)

    // The gate kept its state, so the eventual release still stops this dictation
    // rather than routing to `.none` as it would after a reset.
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
  }

  @Test("dropped-event recovery discards a recording whose key-up was lost")
  func recoveryAfterReleaseDiscardsTheRecording() {
    // The trigger is no longer held, so its key-up was among the dropped events and
    // will never arrive. Left latched, the session would sit in `.recording` until
    // the auto-release cap pasted an unprompted transcript — so the reset must
    // report the discarded recording for the host to cancel upstream.
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)

    let discarded = router.recoverFromDroppedEvents(triggerStillHeld: false)
    #expect(discarded)

    // The tracker was cleared with the gate, so a stale up can't emit a spurious
    // `.stop`, and the next press starts cleanly.
    #expect(router.handle(upEvent(trigger), at: .milliseconds(300)) == .none)
    #expect(router.handle(downEvent(trigger), at: .seconds(2)) == .start)
  }

  @Test("dropped-event recovery over an idle gate discards nothing, either way")
  func recoveryWhileIdleDiscardsNothing() {
    // The common case: the tap times out with no dictation in flight. Neither
    // branch may claim a recording was discarded, or the host cancels a session
    // that was never recording.
    var router = modifierRouter()
    let discardedAfterRelease = router.recoverFromDroppedEvents(triggerStillHeld: false)
    #expect(!discardedAfterRelease)
    let discardedWhileHeld = router.recoverFromDroppedEvents(triggerStillHeld: true)
    #expect(!discardedWhileHeld)
    // Still usable afterwards.
    #expect(router.handle(downEvent(trigger), at: .seconds(1)) == .start)
  }

  @Test("dropped-event recovery discards a latched (tap-to-toggle) recording")
  func recoveryDiscardsALatchedRecording() {
    // A tapped recording has no key held by definition, so `triggerStillHeld` is
    // false and the gate is latched — the state most at risk of being stranded,
    // since nothing is coming to close it.
    var router = modifierRouter()
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(100)) == .none)  // latched

    let discarded = router.recoverFromDroppedEvents(triggerStillHeld: false)
    #expect(discarded)
  }
}
