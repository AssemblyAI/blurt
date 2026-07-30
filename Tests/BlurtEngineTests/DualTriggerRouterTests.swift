import Testing

@testable import BlurtEngine

/// The dual router's jobs on top of `DictationKeyGate` (whose tap/hold semantics
/// have their own suites): route two keys' flag *edges* into one shared gate,
/// report which mode opened a session on `.start`, ignore the non-owning key
/// while a session is live, dedup repeated flag deliveries, and report a
/// discarded recording on reset/rebind.
@Suite("DualTriggerRouter")
struct DualTriggerRouterTests {
  private let raw = TriggerKey.rightOption.keyCode
  private let cleaned = TriggerKey.rightCommand.keyCode

  private func rawDown() -> DualTriggerRouter.Event {
    .flagsChanged(keyCode: raw, rawFlagIsOn: true, cleanedFlagIsOn: false)
  }
  private func rawUp() -> DualTriggerRouter.Event {
    .flagsChanged(keyCode: raw, rawFlagIsOn: false, cleanedFlagIsOn: false)
  }
  private func cleanedDown() -> DualTriggerRouter.Event {
    .flagsChanged(keyCode: cleaned, rawFlagIsOn: false, cleanedFlagIsOn: true)
  }
  private func cleanedUp() -> DualTriggerRouter.Event {
    .flagsChanged(keyCode: cleaned, rawFlagIsOn: false, cleanedFlagIsOn: false)
  }

  private func makeRouter() -> DualTriggerRouter {
    DualTriggerRouter(rawKeyCode: raw, cleanedKeyCode: cleaned)
  }

  private func start(_ mode: DictationMode) -> DualTriggerRouter.Outcome {
    .init(action: .start, mode: mode)
  }
  private func plain(_ action: DictationKeyGate.Action) -> DualTriggerRouter.Outcome {
    .init(action: action, mode: nil)
  }

  @Test("a held raw press is start(.raw) → stop")
  func rawHoldIsStartStop() {
    var router = makeRouter()
    #expect(router.handle(rawDown(), at: .zero) == start(.raw))
    // A start reports the owning mode; the stop does not.
    #expect(router.handle(rawUp(), at: .seconds(2)) == plain(.stop))
  }

  @Test("a cleaned tap latches; the next tap stops, and start reports .cleaned")
  func cleanedTapToToggle() {
    var router = makeRouter()
    #expect(router.handle(cleanedDown(), at: .zero) == start(.cleaned))
    #expect(router.handle(cleanedUp(), at: .milliseconds(200)) == plain(.none))  // latched
    #expect(router.handle(cleanedDown(), at: .seconds(5)) == plain(.none))
    #expect(router.handle(cleanedUp(), at: .seconds(5) + .milliseconds(200)) == plain(.stop))
  }

  @Test("another key over a fresh press is a combo and cancels")
  func comboCancelsFreshCapture() {
    var router = makeRouter()
    #expect(router.handle(rawDown(), at: .zero) == start(.raw))
    #expect(router.handle(.keyDown(keyCode: 8), at: .milliseconds(100)) == plain(.cancel))  // ⌘C
  }

  @Test("a trigger's own keyDown is not a combo")
  func triggerKeyDownIsNotACombo() {
    var router = makeRouter()
    #expect(router.handle(rawDown(), at: .zero) == start(.raw))
    #expect(router.handle(.keyDown(keyCode: raw), at: .milliseconds(100)) == plain(.none))
    #expect(router.handle(.keyDown(keyCode: cleaned), at: .milliseconds(150)) == plain(.none))
    #expect(router.handle(rawUp(), at: .seconds(2)) == plain(.stop))
  }

  @Test("a repeated down-state delivery doesn't re-fire the gate")
  func repeatedDownStateIsDeduped() {
    var router = makeRouter()
    #expect(router.handle(rawDown(), at: .zero) == start(.raw))
    // A re-reported still-down bit must not re-arm the gate (corrupting timing).
    #expect(router.handle(rawDown(), at: .milliseconds(50)) == plain(.none))
    #expect(router.handle(rawUp(), at: .seconds(2)) == plain(.stop))
  }

  @Test("an up-state delivery with no tracked down is ignored")
  func upWithoutDownIsIgnored() {
    var router = makeRouter()
    #expect(router.handle(rawUp(), at: .zero) == plain(.none))
    #expect(router.handle(cleanedUp(), at: .zero) == plain(.none))
  }

  @Test("flag changes for an unbound keycode never reach the gate")
  func unboundKeycodeIsIgnored() {
    var router = makeRouter()
    // keycode 99 is neither trigger; the bits are irrelevant.
    #expect(
      router.handle(.flagsChanged(keyCode: 99, rawFlagIsOn: true, cleanedFlagIsOn: true), at: .zero)
        == plain(.none))
  }

  @Test("the other key's flag changes are ignored while a session is active")
  func otherKeyIgnoredWhileActive() {
    var router = makeRouter()
    #expect(router.handle(cleanedDown(), at: .zero) == start(.cleaned))
    // Raw goes down and up while the cleaned session owns the gate: both inert,
    // and neither disturbs the running dictation.
    #expect(router.handle(rawDown(), at: .milliseconds(100)) == plain(.none))
    #expect(router.handle(rawUp(), at: .milliseconds(200)) == plain(.none))
    // The cleaned key still stops its own (held) session.
    #expect(router.handle(cleanedUp(), at: .seconds(2)) == plain(.stop))
  }

  @Test("ownership clears on stop, so the other key can start the next session")
  func ownershipClearsBetweenSessions() {
    var router = makeRouter()
    #expect(router.handle(rawDown(), at: .zero) == start(.raw))
    #expect(router.handle(rawUp(), at: .seconds(2)) == plain(.stop))
    // A fresh session from the other key reports its own mode.
    #expect(router.handle(cleanedDown(), at: .seconds(3)) == start(.cleaned))
    #expect(router.handle(cleanedUp(), at: .seconds(5)) == plain(.stop))
  }

  @Test("reset while idle reports nothing discarded")
  func resetWhileIdle() {
    var router = makeRouter()
    let discarded = router.reset()
    #expect(!discarded)
  }

  @Test("reset mid-recording discards the live state and clears trackers")
  func resetMidRecordingReportsDiscard() {
    var router = makeRouter()
    #expect(router.handle(rawDown(), at: .zero) == start(.raw))
    let discarded = router.reset()
    #expect(discarded)
    // Trackers and ownership cleared: the stale key-up is inert, a new press
    // (on either key) starts cleanly.
    #expect(router.handle(rawUp(), at: .seconds(2)) == plain(.none))
    #expect(router.handle(cleanedDown(), at: .seconds(3)) == start(.cleaned))
  }

  @Test("rebind mid-recording discards it and switches keycodes")
  func rebindMidRecording() {
    var router = makeRouter()
    #expect(router.handle(cleanedDown(), at: .zero) == start(.cleaned))
    let discarded = router.rebind(rawKeyCode: cleaned, cleanedKeyCode: raw)  // swap the two
    #expect(discarded)
    #expect(router.rawKeyCode == cleaned)
    #expect(router.cleanedKeyCode == raw)
    // The keycode that was "cleaned" now drives the raw mode.
    #expect(
      router.handle(.flagsChanged(keyCode: cleaned, rawFlagIsOn: true, cleanedFlagIsOn: false), at: .seconds(1))
        == start(.raw))
  }

  @Test("rebind while idle reports nothing discarded")
  func rebindWhileIdle() {
    var router = makeRouter()
    let discarded = router.rebind(rawKeyCode: cleaned, cleanedKeyCode: raw)
    #expect(!discarded)
  }
}
