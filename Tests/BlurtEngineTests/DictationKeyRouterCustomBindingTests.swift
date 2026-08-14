import Testing

@testable import BlurtEngine

/// `DictationKeyRouter` under the Custom binding families — a keyboard chord
/// (`.chord`, riding `keyDown`/`keyUp` plus each event's modifier set) and an
/// extra mouse button (`.mouseButton`, riding `mouseDown`/`mouseUp`). The
/// modifier-binding behavior and the reset/rebind/recovery contract live in
/// `DictationKeyRouterTests`; these suites pin that the custom families share the
/// same edge filter and gate semantics, that a chord needs its **exact** modifier
/// set and ends when any required modifier is released, and that the other-key
/// combo cancel deliberately does NOT apply to either (a chord's own modifiers
/// are part of the trigger, and Mouse4+K names no shortcut to macOS).
@Suite("DictationKeyRouter chord bindings")
struct DictationKeyRouterChordBindingTests {
  /// ⌃⌥D — the chord from the request that prompted this feature.
  private let key = 2
  private let required: TriggerBinding.ChordModifiers = [.control, .option]

  private func chordRouter() -> DictationKeyRouter {
    DictationKeyRouter(binding: .chord(keyCode: key, modifiers: required))
  }

  private func down(_ modifiers: TriggerBinding.ChordModifiers) -> DictationKeyRouter.Event {
    .keyDown(keyCode: key, modifiers: modifiers)
  }

  @Test("a held chord is start → stop (push-to-talk)")
  func chordHoldIsStartStop() {
    var router = chordRouter()
    #expect(router.handle(down(required), at: .zero) == .start)
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(2)) == .stop)
  }

  @Test("a short chord tap latches; the next tap stops")
  func chordTapToToggle() {
    var router = chordRouter()
    #expect(router.handle(down(required), at: .zero) == .start)
    #expect(router.handle(.keyUp(keyCode: key), at: .milliseconds(200)) == .none)  // latched
    #expect(router.handle(down(required), at: .seconds(5)) == .none)
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(5) + .milliseconds(200)) == .stop)
  }

  @Test("a repeated keyDown of the held chord doesn't re-fire the gate")
  func chordAutorepeatIsDeduped() {
    // The host drops autorepeat deliveries, but the edge filter must hold on its
    // own — a second down with no up between is not an edge.
    var router = chordRouter()
    #expect(router.handle(down(required), at: .zero) == .start)
    #expect(router.handle(down(required), at: .milliseconds(500)) == .none)
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(2)) == .stop)
  }

  @Test("the chord needs its exact modifier set — too few, too many, or wrong ones do nothing")
  func chordNeedsExactModifiers() {
    var router = chordRouter()
    #expect(router.handle(down([]), at: .zero) == .none)  // bare D types, never triggers
    #expect(router.handle(down([.control]), at: .milliseconds(10)) == .none)  // half the chord
    #expect(router.handle(down([.command, .option]), at: .milliseconds(20)) == .none)  // wrong one
    // A superset is a *different* shortcut (⌃⌥⇧D), so it must not fire either.
    #expect(router.handle(down([.control, .option, .shift]), at: .milliseconds(30)) == .none)
    // And the exact set still works afterwards — none of the above armed the gate.
    #expect(router.handle(down(required), at: .milliseconds(40)) == .start)
  }

  @Test("another key's keyDown never drives or cancels a chord binding")
  func chordIgnoresOtherKeys() {
    var router = chordRouter()
    #expect(router.handle(down(required), at: .zero) == .start)
    // Typing while the chord is held (or latched) is just typing: a chord binding
    // has no combo rule, so this must not cancel the dictation.
    #expect(router.handle(.keyDown(keyCode: 8, modifiers: required), at: .milliseconds(50)) == .none)
    #expect(router.handle(.keyUp(keyCode: 8), at: .milliseconds(60)) == .none)
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(2)) == .stop)
  }

  @Test("releasing a required modifier ends the press, even before the key's keyUp")
  func releasingAModifierEndsThePress() {
    // The realistic release order for ⌃⌥D: the user lets go of ⌃ while D is still
    // down. Waiting for D's keyUp would leave the gate armed with the chord no
    // longer held — and on a hold that means the recording never stops.
    var router = chordRouter()
    #expect(router.handle(down(required), at: .zero) == .start)
    #expect(
      router.handle(
        .flagsChanged(keyCode: 59, triggerFlagIsOn: false, modifiers: [.option]),
        at: .seconds(2)) == .stop)
    // The key's own keyUp then arrives with nothing left to end.
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(2) + .milliseconds(50)) == .none)
  }

  @Test("a modifier release that leaves the chord complete changes nothing")
  func extraModifierReleaseIsInert() {
    var router = chordRouter()
    #expect(router.handle(down(required), at: .zero) == .start)
    // ⇧ was never required, so letting it go leaves ⌃⌥ held: still a live press.
    #expect(
      router.handle(
        .flagsChanged(keyCode: 56, triggerFlagIsOn: false, modifiers: [.control, .option]),
        at: .milliseconds(500)) == .none)
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(2)) == .stop)
  }

  @Test("a modifier release while idle emits nothing")
  func modifierReleaseWhileIdleIsInert() {
    // Ordinary modifier traffic with no dictation in flight must not reach the gate.
    var router = chordRouter()
    #expect(
      router.handle(
        .flagsChanged(keyCode: 59, triggerFlagIsOn: false, modifiers: []), at: .zero) == .none)
    #expect(router.handle(down(required), at: .seconds(1)) == .start)
  }

  @Test("a latched chord recording survives modifier traffic and stops on the next tap")
  func latchedChordSurvivesModifierRelease() {
    // Tap-to-toggle: after the latch the user's hands leave the chord entirely, so
    // the modifier releases that follow must not stop the recording — only the
    // next deliberate tap does.
    var router = chordRouter()
    #expect(router.handle(down(required), at: .zero) == .start)
    #expect(router.handle(.keyUp(keyCode: key), at: .milliseconds(150)) == .none)  // latched
    #expect(
      router.handle(
        .flagsChanged(keyCode: 59, triggerFlagIsOn: false, modifiers: []),
        at: .milliseconds(200)) == .none)
    #expect(router.handle(down(required), at: .seconds(5)) == .none)
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(5) + .milliseconds(150)) == .stop)
  }

  @Test("another key's keyUp and mouse events never reach a chord binding's gate")
  func chordIgnoresOtherFamilies() {
    var router = chordRouter()
    #expect(router.handle(.mouseDown(button: 3), at: .zero) == .none)
    #expect(router.handle(.mouseUp(button: 3), at: .milliseconds(10)) == .none)
    #expect(router.handle(.keyUp(keyCode: 8), at: .milliseconds(20)) == .none)
  }

  @Test("dropped-event recovery keeps a held chord, discards a released one")
  func recoveryForChordBinding() {
    // The host's "still held" read is `keyState` AND the required modifiers via
    // `flagsState`; the router's decision is the same rule as every other family.
    var router = chordRouter()
    #expect(router.handle(down(required), at: .zero) == .start)
    let keptWhileHeld = router.recoverFromDroppedEvents(triggerStillHeld: true)
    #expect(!keptWhileHeld)
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(2)) == .stop)

    #expect(router.handle(down(required), at: .seconds(3)) == .start)
    let discarded = router.recoverFromDroppedEvents(triggerStillHeld: false)
    #expect(discarded)
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(4)) == .none)
  }

  @Test("rebinding from a chord to a modifier discards the live recording")
  func rebindFromChord() {
    var router = chordRouter()
    #expect(router.handle(down(required), at: .zero) == .start)
    let discarded = router.rebind(binding: .modifier(.rightCommand))
    #expect(discarded)
    #expect(router.binding == .modifier(.rightCommand))
    // The chord's keyUp is now irrelevant; the modifier drives dictation.
    #expect(router.handle(.keyUp(keyCode: key), at: .seconds(1)) == .none)
    #expect(
      router.handle(.flagsChanged(keyCode: 54, triggerFlagIsOn: true), at: .seconds(2)) == .start)
  }
}

@Suite("DictationKeyRouter mouse-button bindings")
struct DictationKeyRouterCustomBindingTests {
  private let mouseButton = 3  // "Mouse 4"
  private func mouseRouter() -> DictationKeyRouter {
    DictationKeyRouter(binding: .mouseButton(mouseButton))
  }

  @Test("a held mouse button is start → stop (push-to-talk)")
  func mouseHoldIsStartStop() {
    var router = mouseRouter()
    #expect(router.handle(.mouseDown(button: mouseButton), at: .zero) == .start)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .seconds(2)) == .stop)
  }

  @Test("a short mouse-button click latches; the next click stops")
  func mouseTapToToggle() {
    var router = mouseRouter()
    #expect(router.handle(.mouseDown(button: mouseButton), at: .zero) == .start)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .milliseconds(200)) == .none)
    #expect(router.handle(.mouseDown(button: mouseButton), at: .seconds(5)) == .none)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .seconds(5) + .milliseconds(200)) == .stop)
  }

  @Test("a repeated mouseDown of the held button doesn't re-fire the gate")
  func mouseRepeatIsDeduped() {
    var router = mouseRouter()
    #expect(router.handle(.mouseDown(button: mouseButton), at: .zero) == .start)
    #expect(router.handle(.mouseDown(button: mouseButton), at: .milliseconds(50)) == .none)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .seconds(2)) == .stop)
  }

  @Test("a mouseUp with no tracked down is ignored")
  func mouseUpWithoutDownIsIgnored() {
    var router = mouseRouter()
    #expect(router.handle(.mouseUp(button: mouseButton), at: .zero) == .none)
  }

  @Test("other buttons never reach a mouse binding's gate")
  func mouseBindingIgnoresOtherButtons() {
    var router = mouseRouter()
    #expect(router.handle(.mouseDown(button: 4), at: .zero) == .none)
    #expect(router.handle(.mouseUp(button: 4), at: .milliseconds(50)) == .none)
  }

  @Test("keyboard events never cancel a mouse binding's recording")
  func mouseBindingIgnoresKeyboard() {
    // Typing while a mouse-button dictation is held or latched is just typing —
    // Mouse4+K names no shortcut to macOS, so the modifier bindings' combo
    // cancel deliberately does not apply here.
    var router = mouseRouter()
    #expect(router.handle(.mouseDown(button: mouseButton), at: .zero) == .start)
    #expect(router.handle(.keyDown(keyCode: 8), at: .milliseconds(100)) == .none)
    #expect(
      router.handle(.flagsChanged(keyCode: 54, triggerFlagIsOn: true), at: .milliseconds(200))
        == .none)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .seconds(2)) == .stop)
  }

  @Test("rebind across families: a modifier recording ends when the trigger becomes a mouse button")

  func rebindAcrossFamilies() {
    var router = DictationKeyRouter(binding: .modifier(.rightCommand))
    let down = DictationKeyRouter.Event.flagsChanged(keyCode: 54, triggerFlagIsOn: true)
    #expect(router.handle(down, at: .zero) == .start)

    // Rebinding means the old trigger's up-event can never match — the caller
    // must cancel the capture rather than let the auto-release cap paste it.
    let discarded = router.rebind(binding: .mouseButton(mouseButton))
    #expect(discarded)
    #expect(router.binding == .mouseButton(mouseButton))

    // The old modifier is now irrelevant; the button drives dictation.
    #expect(
      router.handle(.flagsChanged(keyCode: 54, triggerFlagIsOn: false), at: .seconds(1)) == .none)
    #expect(router.handle(.mouseDown(button: mouseButton), at: .seconds(2)) == .start)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .seconds(4)) == .stop)
  }

  @Test("dropped-event recovery keeps a held mouse-button recording, discards a released one")
  func recoveryForMouseBinding() {
    // Same rule as the modifier binding, mouse family: the host's "still held"
    // read comes from `CGEventSource.buttonState` instead of `flagsState`, but
    // the router's decision is identical.
    var router = mouseRouter()
    #expect(router.handle(.mouseDown(button: mouseButton), at: .zero) == .start)

    let keptWhileHeld = router.recoverFromDroppedEvents(triggerStillHeld: true)
    #expect(!keptWhileHeld)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .seconds(2)) == .stop)

    #expect(router.handle(.mouseDown(button: mouseButton), at: .seconds(3)) == .start)
    let discarded = router.recoverFromDroppedEvents(triggerStillHeld: false)
    #expect(discarded)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .seconds(4)) == .none)
  }
}
