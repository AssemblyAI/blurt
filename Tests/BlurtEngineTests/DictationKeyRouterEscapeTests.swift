import Synchronization
import Testing

@testable import BlurtEngine

/// Escape routing: with its switch on, a bare escape is a `.discard` that resets
/// the router whenever something is live or in flight, and inert otherwise; with
/// it off, escape is the ordinary key it is on main, and nothing else is asked.
@Suite("DictationKeyRouter escape")
struct DictationKeyRouterEscapeTests {
  private let trigger = TriggerKey.rightCommand.keyCode
  private let otherTrigger = TriggerKey.rightOption.keyCode
  private let escape = DictationKeyRouter.Event.escapeDown

  private func router(on: Bool) -> DictationKeyRouter {
    DictationKeyRouter(triggerKeyCodes: [trigger, otherTrigger], escapeCancels: { on })
  }

  @Test("escape discards a live recording, and the trigger's own release is inert")
  func escapeDiscardsRecording() {
    var router = router(on: true)
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(escape, at: .milliseconds(100)) == .discard)
    #expect(router.handle(.up(trigger), at: .seconds(2)) == .none)
    #expect(router.handle(.down(trigger), at: .seconds(3)) == .start)
  }

  @Test("escape discards a latched toggle recording")
  func escapeDiscardsLatchedRecording() {
    // The gap the feature exists to close: a tap-to-toggle recording is held by
    // the gate with no key down, and `otherKeyDown` passes through there by
    // design, so before escape routing nothing short of a second tap ended it.
    var router = router(on: true)
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(.up(trigger), at: .milliseconds(200)) == .latch)
    #expect(router.handle(escape, at: .seconds(3)) == .discard)
    #expect(router.handle(.down(trigger), at: .seconds(5)) == .start)
  }

  @Test("a discard frees the router: another trigger works at once")
  func discardClearsTheActiveKey() {
    // A read or rewrite press deciding or selected holds the gate armed under its
    // key; a discard that cleared only the gate left that key owning the router,
    // so every other trigger was ignored until it was let go.
    var router = router(on: true)
    #expect(router.handle(.down(otherTrigger), at: .zero) == .start)
    #expect(router.handle(escape, at: .milliseconds(100)) == .discard)
    #expect(router.activeKeyCode == nil)
    #expect(router.handle(.down(trigger), at: .milliseconds(200)) == .start)
  }

  @Test("escape discards whatever the host reports in flight, with the gate idle")
  func escapeDiscardsInFlightWork() {
    // A hold that has already stopped leaves the gate idle while the transcript
    // is fetched and pasted; a job or a spoken answer after a hand-back does too.
    var router = router(on: true)
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(.up(trigger), at: .seconds(2)) == .stop)
    #expect(router.handle(escape, at: .seconds(2) + .milliseconds(300)) { true } == .discard)
  }

  @Test("escape is inert with nothing live or in flight")
  func escapeIsInertWhenIdle() {
    // The tap is listen-only and sees every escape pressed anywhere on the
    // system, so an idle host must not turn each one into a discard.
    var router = router(on: true)
    #expect(router.handle(escape, at: .zero) { false } == .none)
    #expect(router.handle(.down(trigger), at: .seconds(1)) == .start)
  }

  @Test("escape is not treated as a combo over a latched recording")
  func escapeIsNotACombo() {
    var router = router(on: true)
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(.up(trigger), at: .milliseconds(200)) == .latch)
    #expect(router.handle(.keyDown(keyCode: 8), at: .seconds(1)) == .none)  // ⌘C passes through
    #expect(router.handle(escape, at: .seconds(2)) == .discard)
  }

  /// Switch off must be exactly main, where escape reached the router as an
  /// ordinary `keyDown(53)`. Each scenario runs both ways and must agree.
  @Test(
    "with the switch off, escape gives exactly main's action",
    arguments: [
      [DictationKeyRouter.Event](),  // idle
      [.flagsChanged(keyCode: 54, triggerFlagIsOn: true)],  // armed from idle
      // latched
      [.flagsChanged(keyCode: 54, triggerFlagIsOn: true), .flagsChanged(keyCode: 54, triggerFlagIsOn: false)],
    ])
  func escapeOffMatchesMain(_ setup: [DictationKeyRouter.Event]) {
    var off = router(on: false)
    var main = router(on: false)
    for (i, event) in setup.enumerated() {
      _ = off.handle(event, at: .milliseconds(100 * i))
      _ = main.handle(event, at: .milliseconds(100 * i))
    }
    let asked = Flag()
    let action = off.handle(escape, at: .seconds(1)) {
      asked.value = true
      return true
    }
    #expect(action == main.handle(.keyDown(keyCode: DictationKeyRouter.escapeKeyCode), at: .seconds(1)))
    #expect(action != .discard)
    // Nothing is asked of the host with the switch off.
    #expect(!asked.value)
  }

  @Test("over a press from idle, a switched-off escape is main's combo cancel")
  func escapeOffOverArmedIsCancel() {
    var router = router(on: false)
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(escape, at: .milliseconds(100)) == .cancel)
  }

  @Test("the switch is read at each escape, not at construction")
  func escapeReadsTheSwitchAtKeyTime() {
    let enabled = Flag()
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { enabled.value })
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(.up(trigger), at: .milliseconds(200)) == .latch)
    #expect(router.handle(escape, at: .seconds(1)) == .none)
    enabled.value = true
    #expect(router.handle(escape, at: .seconds(2)) == .discard)
  }

  @Test("only a bare, non-repeating Escape is the gesture")
  func bareEscapeOnly() {
    let esc = DictationKeyRouter.escapeKeyCode
    #expect(DictationKeyRouter.Event.isBareEscape(keyCode: esc, rawFlags: 0, isAutorepeat: false))
    // Caps Lock and fn are not modifiers that make it a shortcut.
    #expect(DictationKeyRouter.Event.isBareEscape(keyCode: esc, rawFlags: 0x1_0000 | 0x80_0000, isAutorepeat: false))
    #expect(!DictationKeyRouter.Event.isBareEscape(keyCode: esc, rawFlags: 0, isAutorepeat: true))
    for modifier: UInt64 in [0x10_0000, 0x8_0000, 0x4_0000, 0x2_0000] {  // ⌘ ⌥ ⌃ ⇧
      #expect(!DictationKeyRouter.Event.isBareEscape(keyCode: esc, rawFlags: modifier, isAutorepeat: false))
    }
    #expect(!DictationKeyRouter.Event.isBareEscape(keyCode: 8, rawFlags: 0, isAutorepeat: false))
  }
}

/// A switch the test flips between two keystrokes.
private final class Flag: Sendable {
  private let state = Mutex(false)
  var value: Bool {
    get { state.withLock { $0 } }
    set { state.withLock { $0 = newValue } }
  }
}
