import Testing

@testable import BlurtEngine

/// `DictationKeyRouter` under the Custom binding family — an extra mouse button
/// (`.mouseButton`), which rides `mouseDown`/`mouseUp` instead of
/// `flagsChanged`. The modifier-binding behavior and the reset/rebind/recovery
/// contract live in `DictationKeyRouterTests`; this suite pins that the mouse
/// family shares the same edge filter and gate semantics, and that the
/// other-key combo cancel deliberately does NOT apply to it (Mouse4+K names no
/// shortcut to macOS — a key while the button is held is just typing).
@Suite("DictationKeyRouter custom bindings")
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
