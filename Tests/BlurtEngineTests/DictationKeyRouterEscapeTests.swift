import Synchronization
import Testing

@testable import BlurtEngine

/// Escape routing on top of `DictationKeyGate.escapeKeyDown()` (whose per-state
/// semantics have their own scenarios): escape routes to a cancel rather than a
/// combo, keeps cancelling through the transcribe/inject window the gate reads as
/// idle (`dictationIsActive`), and stays inert with nothing in flight — all of
/// it only while developer mode is on. Off, Escape is an ordinary key.
@Suite("DictationKeyRouter escape")
struct DictationKeyRouterEscapeTests {
  private let trigger = TriggerKey.rightCommand.keyCode
  private let escape = DictationKeyRouter.Event.keyDown(keyCode: DictationKeyRouter.escapeKeyCode)

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

  @Test("escape cancels through the post-recording transcribe/inject window")
  func escapeCancelsInFlightPipeline() {
    // A hold that has already stopped leaves the gate idle while the transcript
    // is still being fetched and pasted. The host reports that window via
    // `dictationIsActive`, and escape must still cancel inside it — this is the
    // "Transcribing…" pill the user is looking at when they hit escape.
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { true })
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .seconds(2)) == .stop)
    router.dictationIsActive = true
    #expect(router.handle(escape, at: .seconds(2) + .milliseconds(300)) == .cancel)
  }

  @Test("escape is inert with nothing in flight")
  func escapeIsInertWhenIdle() {
    // The tap is listen-only and sees every escape pressed anywhere on the
    // system, so an idle pipeline must not turn each one into a cancel command.
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { true })
    #expect(router.handle(escape, at: .zero) == .none)
    #expect(router.handle(escape, at: .seconds(1)) == .none)
    // Once the host reports the dictation over, escape is inert again.
    router.dictationIsActive = true
    router.dictationIsActive = false
    #expect(router.handle(escape, at: .seconds(2)) == .none)
    // And escape left nothing broken behind — the next press dictates normally.
    #expect(router.handle(downEvent(trigger), at: .seconds(3)) == .start)
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

  @Test("with developer mode off, escape is an ordinary key: it passes over a latch")
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

  @Test("with developer mode off, escape over a fresh press is a combo, and nothing after")
  func escapeOffIsAComboAndInertOtherwise() {
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { false })
    // Any key over a press from idle cancels it — that was always so.
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(escape, at: .milliseconds(100)) == .cancel)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .none)
    // But the transcribe/inject window is not escape's to cancel.
    router.dictationIsActive = true
    #expect(router.handle(escape, at: .seconds(1)) == .none)
  }

  @Test("the developer-mode switch is read at each escape, not at construction")
  func escapeReadsTheSwitchAtKeyTime() {
    let enabled = Flag()
    var router = DictationKeyRouter(triggerKeyCodes: [trigger], escapeCancels: { enabled.value })
    #expect(router.handle(downEvent(trigger), at: .zero) == .start)
    #expect(router.handle(upEvent(trigger), at: .milliseconds(200)) == .latch)
    #expect(router.handle(escape, at: .seconds(1)) == .none)
    enabled.value = true
    #expect(router.handle(escape, at: .seconds(2)) == .cancel)
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
