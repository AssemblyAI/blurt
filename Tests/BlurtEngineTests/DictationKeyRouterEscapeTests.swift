import Testing

@testable import BlurtEngine

/// Escape routing: with its switch on, a bare escape is a `.discard` that resets
/// the router whenever something is live or in flight, and inert otherwise; with
/// it off, escape is the ordinary key it is on main (`Event.fromKeyDown`).
@Suite("DictationKeyRouter escape")
struct DictationKeyRouterEscapeTests {
  private let trigger = TriggerKey.rightCommand.keyCode
  private let otherTrigger = TriggerKey.rightOption.keyCode
  /// A bare Escape with no key held.
  private let escape = DictationKeyRouter.Event.escapeDown(rawFlags: 0)
  /// An Escape pressed over a held right ⌘, as the tap delivers it.
  private let escapeOverRightCommand = DictationKeyRouter.Event.escapeDown(rawFlags: pressed(.rightCommand))

  private func router() -> DictationKeyRouter {
    DictationKeyRouter(triggerKeyCodes: [trigger, otherTrigger])
  }

  @Test("escape over the held trigger discards its recording, and the trigger's release is inert")
  func escapeDiscardsRecording() {
    var router = router()
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(escapeOverRightCommand, at: .milliseconds(100)) == .discard)
    #expect(router.handle(.up(trigger), at: .seconds(2)) == .none)
    #expect(router.handle(.down(trigger), at: .seconds(3)) == .start)
  }

  @Test(
    "a trigger held through a discard can't re-start it until let go, even past the dictation's own reset",
    arguments: [false, true])
  func heldTriggerReReportIsInert(resetAgain: Bool) {
    // `flagsChanged` re-reports a held key's bit; after a discard cleared the
    // edge tracker, that re-report read as a fresh press and started a new
    // dictation the moment the user threw one away. The discard's session
    // cancel then lands a terminal phase, whose `syncAfterTerminalPhase`
    // resets the router a second time, the key still held.
    var router = router()
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(escapeOverRightCommand, at: .milliseconds(100)) == .discard)
    if resetAgain {
      let discardedAgain = router.reset()
      #expect(!discardedAgain)
    }
    #expect(router.handle(.down(trigger), at: .milliseconds(200)) == .none)
    #expect(router.handle(.up(trigger), at: .seconds(1)) == .none)
    #expect(router.handle(.down(trigger), at: .seconds(2)) == .start)
  }

  @Test("dropped events release a held-through key the flags say is up")
  func recoveryTrustsTheFlags() {
    var router = router()
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(escapeOverRightCommand, at: .milliseconds(100)) == .discard)
    // Its release was among the dropped events: the next press is a press.
    router.recoverFromDroppedEvents(heldFlags: 0)
    #expect(router.handle(.down(trigger), at: .seconds(1)) == .start)
  }

  @Test("escape over a held press waiting on in-flight work discards it")
  func escapeOverHeldIdleGate() {
    // A combo leaves the gate idle with the trigger still down; an Escape over
    // it, with the host busy, is still the cancel.
    var router = router()
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(.keyDown(keyCode: 8), at: .milliseconds(50)) == .cancel)
    #expect(router.handle(escapeOverRightCommand, at: .milliseconds(100)) { true } == .discard)
  }

  @Test("escape discards a latched toggle recording")
  func escapeDiscardsLatchedRecording() {
    // The gap the feature exists to close: a tap-to-toggle recording is held by
    // the gate with no key down, and `otherKeyDown` passes through there by
    // design, so before escape routing nothing short of a second tap ended it.
    var router = router()
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
    var router = router()
    #expect(router.handle(.down(otherTrigger), at: .zero) == .start)
    #expect(router.handle(.escapeDown(rawFlags: pressed(.rightOption)), at: .milliseconds(100)) == .discard)
    #expect(router.activeKeyCode == nil)
    #expect(router.handle(.down(trigger), at: .milliseconds(200)) == .start)
  }

  @Test("escape discards whatever the host reports in flight, with the gate idle")
  func escapeDiscardsInFlightWork() {
    // A hold that has already stopped leaves the gate idle while the transcript
    // is fetched and pasted; a job or a spoken answer after a hand-back does too.
    var router = router()
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(.up(trigger), at: .seconds(2)) == .stop)
    #expect(router.handle(escape, at: .seconds(2) + .milliseconds(300)) { true } == .discard)
  }

  @Test("escape is inert with nothing live or in flight")
  func escapeIsInertWhenIdle() {
    // The tap is listen-only and sees every escape pressed anywhere on the
    // system, so an idle host must not turn each one into a discard.
    var router = router()
    #expect(router.handle(escape, at: .zero) { false } == .none)
    #expect(router.handle(.down(trigger), at: .seconds(1)) == .start)
  }

  @Test("escape is not treated as a combo over a latched recording")
  func escapeIsNotACombo() {
    var router = router()
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(.up(trigger), at: .milliseconds(200)) == .latch)
    #expect(router.handle(.keyDown(keyCode: 8), at: .seconds(1)) == .none)  // ⌘C passes through
    #expect(router.handle(escape, at: .seconds(2)) == .discard)
  }

  @Test("an Escape candidate is a non-repeating Escape with the switch on; anything else is main's key")
  func escapeCandidates() {
    let esc = DictationKeyRouter.escapeKeyCode
    typealias Event = DictationKeyRouter.Event
    #expect(
      Event.fromKeyDown(keyCode: esc, isAutorepeat: false, escapeCancels: true, rawFlags: 7) == .escapeDown(rawFlags: 7)
    )
    // Switch off: exactly the ordinary key it was before the gesture existed.
    #expect(
      Event.fromKeyDown(keyCode: esc, isAutorepeat: false, escapeCancels: false, rawFlags: 0) == .keyDown(keyCode: esc))
    #expect(
      Event.fromKeyDown(keyCode: esc, isAutorepeat: true, escapeCancels: true, rawFlags: 0) == .keyDown(keyCode: esc))
    #expect(
      Event.fromKeyDown(keyCode: 8, isAutorepeat: false, escapeCancels: true, rawFlags: 0) == .keyDown(keyCode: 8))
  }

  @Test("any other key reads neither the switch nor the flags")
  func otherKeysReadNothing() {
    let read = ValueBox(false)
    func touched<T>(_ value: T) -> T {
      read.value = true
      return value
    }
    let event = DictationKeyRouter.Event.fromKeyDown(
      keyCode: 8, isAutorepeat: touched(false), escapeCancels: touched(true), rawFlags: touched(0))
    #expect(event == .keyDown(keyCode: 8))
    #expect(!read.value)
  }

  @Test(
    "with nothing held, any ⌘ ⌥ ⌃ ⇧ makes escape a shortcut; Caps Lock and fn don't",
    arguments: unheldCases)
  func bareWithNothingHeld(flags: UInt64, isBare: Bool) {
    var router = router()
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    #expect(router.handle(.up(trigger), at: .milliseconds(200)) == .latch)
    #expect((router.handle(.escapeDown(rawFlags: flags), at: .seconds(1)) == .discard) == isBare)
  }

  @Test("over a held trigger, only its own modifier is allowed", arguments: heldCases)
  func bareOverHeldTrigger(flags: UInt64, isBare: Bool) {
    var router = router()
    #expect(router.handle(.down(trigger), at: .zero) == .start)
    let action = router.handle(.escapeDown(rawFlags: flags), at: .milliseconds(100))
    // A shortcut over a press from idle is that press's combo cancel.
    #expect(action == (isBare ? .discard : .cancel))
  }
}

/// The raw flags a lone press of `key` sets: its generic bit and its device bit.
private func pressed(_ key: TriggerKey) -> UInt64 { key.sharedModifierMask | key.deviceModifierMask }

/// An Escape's raw flags with nothing held, and whether it is bare.
private let unheldCases: [(UInt64, Bool)] = [
  (0x1_0000 | TriggerKey.function.deviceModifierMask, true),  // Caps Lock and fn
  (TriggerKey.commandFlag, false),
  (TriggerKey.optionFlag, false),
  (TriggerKey.controlFlag, false),
  (TriggerKey.shiftFlag, false),
]

/// An Escape's raw flags over a held right ⌘, and whether it is bare.
private let heldCases: [(UInt64, Bool)] = [
  (pressed(.rightCommand), true),
  (pressed(.rightCommand) | pressed(.leftCommand), false),  // both ⌘s: ⌘Esc
  (pressed(.rightCommand) | pressed(.leftOption), false),  // ⌥⌘Esc, Force Quit
  (pressed(.rightCommand) | TriggerKey.shiftFlag, false),  // ⇧⌘Esc
]
