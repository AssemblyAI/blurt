import Synchronization
import Testing

@testable import BlurtEngine

/// Escape routing on top of `DictationKeyGate.escapeKeyDown()` (whose per-state
/// semantics have their own scenarios): a bare escape routes to a cancel rather
/// than a combo, keeps cancelling while the host reports something in flight the
/// gate can't see, and stays inert with nothing in flight — all of it only while
/// the switch is on. Off, Escape is an ordinary key.
@Suite("DictationKeyRouter escape")
struct DictationKeyRouterEscapeTests {
  private let trigger = TriggerKey.rightCommand.keyCode
  private let escape = DictationKeyRouter.Event.escapeDown(inFlight: false)
  private let escapeInFlight = DictationKeyRouter.Event.escapeDown(inFlight: true)

  private func downEvent(_ keyCode: Int) -> DictationKeyRouter.Event {
    .flagsChanged(keyCode: keyCode, triggerFlagIsOn: true)
  }

  private func upEvent(_ keyCode: Int) -> DictationKeyRouter.Event {
    .flagsChanged(keyCode: keyCode, triggerFlagIsOn: false)
  }

  @Test("escape cancels a live recording the gate is tracking")
  func escapeCancelsRecording() {
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { true })
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(escape, at: .milliseconds(100)) == .cancel)
    // The trigger's own release, still to come, must not re-stop it.
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .none)
    #expect(router.handle(downEvent(trigger), at: .seconds(3)) == .start)
  }

  @Test("escape cancels a latched toggle recording")
  func escapeCancelsLatchedRecording() {
    // The gap the feature exists to close: a tap-to-toggle recording is held by
    // the gate with no key down, and `otherKeyDown` passes through there by
    // design, so before escape routing nothing short of a second tap ended it.
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { true })
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .latch)
    #expect(router.handle(escape, at: .seconds(3)) == .cancel)
    // Cancelling cleared the latch, so the next tap starts a fresh dictation
    // rather than being swallowed as a stop.
    #expect(router.handle(downEvent(trigger), at: .seconds(5)) == .start)
  }

  @Test("escape cancels whatever the host reports in flight, with the gate idle")
  func escapeCancelsInFlightWork() {
    // A hold that has already stopped leaves the gate idle while the transcript
    // is fetched and pasted; a job or a spoken answer after a hand-back does too.
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { true })
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
    #expect(router.handle(escapeInFlight, at: .seconds(2) + .milliseconds(300)) == .cancel)
  }

  @Test("escape is inert with nothing in flight, and doesn't read the switch")
  func escapeIsInertWhenIdle() {
    // The tap is listen-only and sees every escape pressed anywhere on the
    // system, so an idle host must not turn each one into a cancel, nor pay for
    // a defaults read on each.
    let reads = SwitchReads()
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { reads.bump() })
    #expect(router.handle(escape, at: .zero) == .none)
    #expect(router.handle(escape, at: .seconds(1)) == .none)
    #expect(reads.total == 0)
    // And escape left nothing broken behind — the next press dictates normally.
    #expect(router.handle(downEvent(trigger), at: .seconds(3)) == .start)
    #expect(router.handle(escape, at: .seconds(4)) == .cancel)
    #expect(reads.total == 1)
  }

  @Test("escape is not treated as a combo over a latched recording")
  func escapeIsNotACombo() {
    // `keyDown` for an ordinary key over a latch is a pass-through shortcut; the
    // two routes must not be confused, or ⌘C would cancel (or escape wouldn't).
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { true })
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .latch)
    #expect(router.handle(.keyDown(keyCode: 8), at: .seconds(1)) == .none)  // ⌘C passes through
    #expect(router.handle(escape, at: .seconds(2)) == .cancel)
  }

  @Test("with the switch off, escape is an ordinary key: it passes over a latch")
  func escapeOffPassesThroughLatch() {
    // Exactly the pre-gesture behaviour: over a latched recording any other key,
    // escape included, is a shortcut that leaves the recording running.
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { false })
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .latch)
    #expect(router.handle(escape, at: .seconds(1)) == .none)
    #expect(router.handle(downEvent(trigger), at: .seconds(2)) == .none)
    #expect(router.handle(upEvent(trigger), at: .seconds(2) + .milliseconds(100)) == .stop)
  }

  @Test("with the switch off, escape over a fresh press is a combo, and nothing after")
  func escapeOffIsAComboAndInertOtherwise() {
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { false })
    // Any key over a press from idle cancels it — that was always so.
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(escape, at: .milliseconds(100)) == .cancel)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .none)
    // But what's in flight past the gate is not escape's to cancel.
    #expect(router.handle(escapeInFlight, at: .seconds(1)) == .none)
  }

  @Test("the switch is read at each escape, not at construction")
  func escapeReadsTheSwitchAtKeyTime() {
    let enabled = Flag()
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { enabled.value })
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .latch)
    #expect(router.handle(escape, at: .seconds(1)) == .none)
    enabled.value = true
    #expect(router.handle(escape, at: .seconds(2)) == .cancel)
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

/// Counts reads of the switch; always reads on.
private final class SwitchReads: Sendable {
  private let state = Mutex(0)
  var total: Int { state.withLock { $0 } }
  func bump() -> Bool {
    state.withLock { $0 += 1 }
    return true
  }
}
