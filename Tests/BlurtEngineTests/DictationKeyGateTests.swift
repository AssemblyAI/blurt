import Testing

@testable import BlurtEngine

@Suite("DictationKeyGate")
struct DictationKeyGateTests {
  /// One driver event. `reset` returns nothing; every other event returns an
  /// `Action` the scenario asserts.
  enum Event: Sendable {
    case down(Duration)
    case up(Duration)
    case other
    case reset
  }

  /// An event plus the `Action` it must return (`nil` for steps whose return is
  /// intentionally ignored, and for `reset`, which returns nothing).
  struct Step: Sendable {
    let event: Event
    let expect: DictationKeyGate.Action?
    init(_ event: Event, _ expect: DictationKeyGate.Action? = nil) {
      self.event = event
      self.expect = expect
    }
  }

  /// A named sequence of steps run against a fresh gate. Replaces what used to be
  /// a dozen near-identical `@Test`s — the tap/hold/latch/combo state machine is
  /// exactly the kind of input→output table `arguments:` is for, and a failure
  /// now names the scenario. `activation` defaults to the shipped tap-or-hold
  /// mode, so the pre-setting scenarios read (and assert) exactly as before.
  struct Scenario: Sendable, CustomTestStringConvertible {
    let name: String
    let steps: [Step]
    let activation: TriggerActivation
    var testDescription: String { name }

    init(name: String, steps: [Step], activation: TriggerActivation = .tapOrHold) {
      self.name = name
      self.steps = steps
      self.activation = activation
    }
  }

  static let scenarios: [Scenario] = [
    Scenario(name: "modifier down from idle starts recording", steps: [.init(.down(.seconds(0)), .start)]),
    Scenario(
      name: "quick tap latches on — release does not stop (a later solo tap does)",
      steps: [
        .init(.down(.seconds(0))), .init(.up(.milliseconds(200)), DictationKeyGate.Action.none),
        .init(.down(.seconds(5))), .init(.up(.milliseconds(5100)), .stop),
      ]),
    Scenario(
      name: "a second tap while latched stops recording",
      steps: [
        .init(.down(.seconds(0))), .init(.up(.milliseconds(200))),
        .init(.down(.seconds(5)), DictationKeyGate.Action.none), .init(.up(.milliseconds(5100)), .stop),
      ]),
    Scenario(
      name: "hold past threshold then release stops (push-to-talk)",
      steps: [.init(.down(.seconds(0))), .init(.up(.milliseconds(1200)), .stop)]),
    Scenario(
      name: "after a hold stops, the next press starts fresh",
      steps: [
        .init(.down(.seconds(0))), .init(.up(.milliseconds(1200))), .init(.down(.seconds(2)), .start),
      ]),
    Scenario(
      name: "release exactly at threshold counts as a hold (stop)",
      steps: [.init(.down(.seconds(0))), .init(.up(.seconds(1)), .stop)]),
    Scenario(
      name: "release just under threshold is a tap (latch, not stop)",
      steps: [
        .init(.down(.seconds(0))), .init(.up(.milliseconds(999)), DictationKeyGate.Action.none),
        .init(.down(.seconds(5))), .init(.up(.milliseconds(5100)), .stop),
      ]),
    Scenario(
      name: "a combo from idle cancels the just-started capture",
      steps: [
        .init(.down(.seconds(0))), .init(.other, .cancel),
        .init(.up(.milliseconds(100)), DictationKeyGate.Action.none), .init(.down(.seconds(2)), .start),
      ]),
    Scenario(
      name: "a combo while latched keeps recording (does not cancel)",
      steps: [
        .init(.down(.seconds(0))), .init(.up(.milliseconds(200))),
        .init(.down(.seconds(5))), .init(.other, DictationKeyGate.Action.none),
        .init(.up(.milliseconds(5100)), DictationKeyGate.Action.none),
        .init(.down(.seconds(10))), .init(.up(.milliseconds(10100)), .stop),
      ]),
    Scenario(
      name: "otherKeyDown while idle is ignored",
      steps: [.init(.other, DictationKeyGate.Action.none), .init(.down(.seconds(1)), .start)]),
    Scenario(
      name: "modifier up without a prior down is ignored",
      steps: [.init(.up(.seconds(1)), DictationKeyGate.Action.none)]),
    Scenario(
      name: "reset clears state so the next press starts fresh",
      steps: [.init(.down(.seconds(0))), .init(.reset), .init(.down(.seconds(2)), .start)]),
    Scenario(
      name: "a repeated modifier down while armed is ignored (no double start)",
      steps: [
        .init(.down(.seconds(0)), .start), .init(.down(.milliseconds(100)), DictationKeyGate.Action.none),
        .init(.up(.milliseconds(1200)), .stop),
      ]),
    Scenario(
      name: "a rapid second tap while latched still stops (no multi-tap gesture)",
      steps: [
        .init(.down(.milliseconds(0)), .start), .init(.up(.milliseconds(80))),
        .init(.down(.milliseconds(200)), DictationKeyGate.Action.none), .init(.up(.milliseconds(280)), .stop),
        .init(.down(.seconds(5)), .start),
      ]),
    Scenario(
      name: "tap mode: a release past the hold threshold still latches (no push-to-talk)",
      steps: [
        .init(.down(.seconds(0)), .start), .init(.up(.milliseconds(1200)), DictationKeyGate.Action.none),
        .init(.down(.seconds(5)), DictationKeyGate.Action.none), .init(.up(.milliseconds(5100)), .stop),
      ],
      activation: .tap),
    Scenario(
      name: "tap mode: a quick tap latches and the next tap stops, as in tap-or-hold",
      steps: [
        .init(.down(.seconds(0)), .start), .init(.up(.milliseconds(200)), DictationKeyGate.Action.none),
        .init(.down(.seconds(2)), DictationKeyGate.Action.none), .init(.up(.milliseconds(2100)), .stop),
      ],
      activation: .tap),
    Scenario(
      name: "hold mode: a release under the threshold stops instead of latching",
      steps: [
        .init(.down(.seconds(0)), .start), .init(.up(.milliseconds(200)), .stop),
        .init(.down(.seconds(2)), .start), .init(.up(.milliseconds(3500)), .stop),
      ],
      activation: .hold),
    Scenario(
      name: "hold mode: a combo from idle still cancels the fresh capture",
      steps: [
        .init(.down(.seconds(0)), .start), .init(.other, .cancel),
        .init(.up(.milliseconds(100)), DictationKeyGate.Action.none), .init(.down(.seconds(2)), .start),
      ],
      activation: .hold),
  ]

  @Test("tap/hold/latch/combo state machine", arguments: scenarios)
  func gate(_ scenario: Scenario) {
    var g = DictationKeyGate(holdThreshold: .seconds(1), activation: scenario.activation)
    for (i, step) in scenario.steps.enumerated() {
      let action: DictationKeyGate.Action?
      switch step.event {
      case .down(let t): action = g.modifierDown(at: t)
      case .up(let t): action = g.modifierUp(at: t)
      case .other: action = g.otherKeyDown()
      case .reset:
        g.reset()
        action = nil
      }
      if let expected = step.expect {
        #expect(action == expected, "step \(i) (\(step.event)) expected \(expected), got \(action as Any)")
      }
    }
  }

  /// `isIdle` is what `DictationKeyRouter.reset()` reads to decide whether it just
  /// discarded a live recording the host must cancel upstream (on a rebind, or the
  /// disabled-tap recovery), so it has to be true exactly when no dictation is in
  /// flight.
  @Test("isIdle tracks armed and latched recordings")
  func isIdleTracksLiveRecordings() {
    var g = DictationKeyGate(holdThreshold: .seconds(1))
    #expect(g.isIdle)
    _ = g.modifierDown(at: .seconds(0))  // armed (push-to-talk in progress)
    #expect(!g.isIdle)
    _ = g.modifierUp(at: .milliseconds(200))  // quick tap → latched
    #expect(!g.isIdle)
    g.reset()
    #expect(g.isIdle)
    _ = g.modifierDown(at: .seconds(2))
    _ = g.modifierUp(at: .milliseconds(3500))  // hold → stop
    #expect(g.isIdle)
  }
}
