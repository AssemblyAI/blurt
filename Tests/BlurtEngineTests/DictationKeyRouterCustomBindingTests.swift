import Testing

@testable import BlurtEngine

/// `DictationKeyRouter` under the Custom binding families — a lone F-key
/// (`.key`) or an extra mouse button (`.mouseButton`) — which ride
/// `keyDown`/`keyUp` and `mouseDown`/`mouseUp` instead of `flagsChanged`. The
/// modifier-binding behavior and the reset/rebind/recovery contract live in
/// `DictationKeyRouterTests`; this suite pins that the custom families share
/// the same edge filter and gate semantics, and that the other-key combo
/// cancel deliberately does NOT apply to them (F5+K and Mouse4+K name no
/// shortcut to macOS — another key while the trigger is held is just typing).
@Suite("DictationKeyRouter custom bindings")
struct DictationKeyRouterCustomBindingTests {
  // MARK: - Key (F-key) bindings

  private let functionKey = 96  // F5
  private func keyRouter() -> DictationKeyRouter {
    DictationKeyRouter(binding: .key(code: functionKey))
  }

  @Test("a held F-key is start → stop (push-to-talk)")
  func keyHoldIsStartStop() {
    var router = keyRouter()
    #expect(router.handle(.keyDown(keyCode: functionKey), at: .zero) == .start)
    #expect(router.handle(.keyUp(keyCode: functionKey), at: .seconds(2)) == .stop)
  }

  @Test("a short F-key tap latches; the next tap stops")
  func keyTapToToggle() {
    var router = keyRouter()
    #expect(router.handle(.keyDown(keyCode: functionKey), at: .zero) == .start)
    #expect(router.handle(.keyUp(keyCode: functionKey), at: .milliseconds(200)) == .none)
    #expect(router.handle(.keyDown(keyCode: functionKey), at: .seconds(5)) == .none)
    #expect(router.handle(.keyUp(keyCode: functionKey), at: .seconds(5) + .milliseconds(200)) == .stop)
  }

  @Test("a repeated keyDown of the held F-key doesn't re-fire the gate")
  func keyAutorepeatIsDeduped() {
    // The tap filters autorepeat deliveries out, but the router's edge dedup
    // must hold on its own — a second down with no up between is not an edge.
    var router = keyRouter()
    #expect(router.handle(.keyDown(keyCode: functionKey), at: .zero) == .start)
    #expect(router.handle(.keyDown(keyCode: functionKey), at: .milliseconds(500)) == .none)
    #expect(router.handle(.keyDown(keyCode: functionKey), at: .milliseconds(600)) == .none)
    #expect(router.handle(.keyUp(keyCode: functionKey), at: .seconds(2)) == .stop)
  }

  @Test("an F-key keyUp with no tracked down is ignored")
  func keyUpWithoutDownIsIgnored() {
    var router = keyRouter()
    #expect(router.handle(.keyUp(keyCode: functionKey), at: .zero) == .none)
  }

  @Test("other keys' downs and ups never reach an F-key binding's gate")
  func keyBindingIgnoresOtherKeycodes() {
    var router = keyRouter()
    #expect(router.handle(.keyDown(keyCode: 122), at: .zero) == .none)  // F1, unbound
    #expect(router.handle(.keyUp(keyCode: 122), at: .milliseconds(50)) == .none)
  }

  @Test("another key while the F-key is held is typing, not a combo — no cancel")
  func keyBindingHasNoComboRule() {
    // F5+K names no shortcut to macOS the way ⌘C does, so a stray key while the
    // trigger is held — or while a tapped recording is latched — must not
    // cancel the dictation; cancelling would punish exactly the typing a
    // latched dictation is for.
    var router = keyRouter()
    #expect(router.handle(.keyDown(keyCode: functionKey), at: .zero) == .start)
    #expect(router.handle(.keyDown(keyCode: 8), at: .milliseconds(100)) == .none)
    #expect(router.handle(.keyUp(keyCode: functionKey), at: .seconds(2)) == .stop)

    #expect(router.handle(.keyDown(keyCode: functionKey), at: .seconds(3)) == .start)
    #expect(router.handle(.keyUp(keyCode: functionKey), at: .seconds(3) + .milliseconds(100)) == .none)
    #expect(router.handle(.keyDown(keyCode: 8), at: .seconds(4)) == .none)  // typing while latched
    #expect(router.handle(.keyDown(keyCode: functionKey), at: .seconds(5)) == .none)
    #expect(router.handle(.keyUp(keyCode: functionKey), at: .seconds(5) + .milliseconds(100)) == .stop)
  }

  @Test("flagsChanged and mouse events never reach an F-key binding's gate")
  func keyBindingIgnoresOtherFamilies() {
    var router = keyRouter()
    // Even a flags delivery reporting the bound keycode: an F-key binding is
    // driven by keyDown/keyUp, and the flag argument is meaningless for it.
    #expect(
      router.handle(.flagsChanged(keyCode: functionKey, triggerFlagIsOn: true), at: .zero) == .none)
    #expect(router.handle(.mouseDown(button: 3), at: .milliseconds(50)) == .none)
    #expect(router.handle(.mouseUp(button: 3), at: .milliseconds(60)) == .none)
  }

  // MARK: - Mouse-button bindings

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
    // same no-combo rule as the F-key binding.
    var router = mouseRouter()
    #expect(router.handle(.mouseDown(button: mouseButton), at: .zero) == .start)
    #expect(router.handle(.keyDown(keyCode: 8), at: .milliseconds(100)) == .none)
    #expect(router.handle(.keyUp(keyCode: 8), at: .milliseconds(150)) == .none)
    #expect(
      router.handle(.flagsChanged(keyCode: 54, triggerFlagIsOn: true), at: .milliseconds(200))
        == .none)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .seconds(2)) == .stop)
  }

  @Test("rebind across families: an F-key recording ends when the trigger becomes a mouse button")
  func rebindAcrossFamilies() {
    var router = keyRouter()
    #expect(router.handle(.keyDown(keyCode: functionKey), at: .zero) == .start)

    let discarded = router.rebind(binding: .mouseButton(mouseButton))
    #expect(discarded)
    #expect(router.binding == .mouseButton(mouseButton))

    // The old F-key is now irrelevant; the button drives dictation.
    #expect(router.handle(.keyUp(keyCode: functionKey), at: .seconds(1)) == .none)
    #expect(router.handle(.mouseDown(button: mouseButton), at: .seconds(2)) == .start)
    #expect(router.handle(.mouseUp(button: mouseButton), at: .seconds(4)) == .stop)
  }

  @Test("dropped-event recovery keeps a held mouse-button recording, discards a released one")
  func recoveryForMouseBinding() {
    // Same rule, mouse family: the host's "still held" read comes from
    // `CGEventSource.buttonState` instead of `flagsState`, but the router's
    // decision is identical.
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
