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
  /// now names the scenario.
  struct Scenario: Sendable, CustomTestStringConvertible {
    let name: String
    let steps: [Step]
    var testDescription: String { name }
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
  ]

  @Test("tap/hold/latch/combo state machine", arguments: scenarios)
  func gate(_ scenario: Scenario) {
    var g = DictationKeyGate(holdThreshold: .seconds(1))
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
}
