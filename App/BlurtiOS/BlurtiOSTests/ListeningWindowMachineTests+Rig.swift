import Foundation
import Testing

@testable import BlurtiOSCore

// MARK: - The rig
//
// Machines in the states the rows start from, and the readers that take a
// transition apart into its state, its effects and the one record it publishes.

extension ListeningWindowMachineTests {
  var window: TimeInterval { TimeInterval(minutes * 60) }

  func fresh(minutes: Int? = nil) -> Machine {
    Machine(launchID: launch, windowMinutes: minutes ?? self.minutes, maxAudioSeconds: maxAudio)
  }

  /// A window opened at `t0` (generation 1) with nothing — or a dictation — in flight; `opened: false` leaves it opening.
  func openWindow(minutes: Int? = nil, opened: Bool = true, dictating: Bool = false) -> Machine {
    var machine = fresh(minutes: minutes)
    _ = machine.handle(.openRequested(inForeground: true), now: t0)
    if opened { _ = machine.handle(.opened(1), now: t0) }
    if dictating { _ = machine.handle(.utteranceStarted(1), now: t0) }
    return machine
  }

  /// An open window a call took the microphone from, at `t0`.
  func interruptedWindow() -> Machine {
    var machine = openWindow()
    _ = machine.handle(.interruptionBegan(1, .interrupted), now: t0)
    return machine
  }

  /// An open window the user stopped at `t0`, its source still closing.
  func closingWindow() -> Machine {
    var machine = openWindow()
    _ = machine.handle(.closeRequested, now: t0)
    return machine
  }

  /// The effects apart from the record they publish.
  func actions(_ effects: [Effect]) -> [Effect] {
    effects.filter { if case .publish = $0 { false } else { true } }
  }

  func records(_ effects: [Effect]) -> [ListeningState] {
    effects.compactMap { if case .publish(let record) = $0 { record } else { nil } }
  }

  /// The one record a transition publishes.
  func record(_ effects: [Effect], at location: SourceLocation = #_sourceLocation) throws -> ListeningState {
    let published = records(effects)
    #expect(published.count == 1, sourceLocation: location)
    return try #require(published.first, sourceLocation: location)
  }

  /// One row: where the event lands the machine and what it asks for, answering the record it publishes.
  @discardableResult
  func row(
    _ machine: inout Machine, _ event: Machine.Event, at now: Date, lands state: Machine.State,
    asks expected: [Effect], location: SourceLocation = #_sourceLocation
  ) throws -> ListeningState {
    let effects = machine.handle(event, now: now)
    #expect(machine.state == state, sourceLocation: location)
    #expect(actions(effects) == expected, sourceLocation: location)
    return try record(effects, at: location)
  }

  /// Every row and a beat after each, in one life: refused, opened, dictated, interrupted, resumed, stopped.
  func wholeLife() -> [ListeningState] {
    var m = fresh()
    var records: [ListeningState] = []
    let steps: [(Machine.Event, TimeInterval)] = [
      (.openRequested(inForeground: false), 0), (.openRequested(inForeground: true), 1), (.opened(1), 2),
      (.utteranceStarted(1), 3), (.utteranceEnded(1), 20), (.interruptionBegan(1, .interrupted), 30),
      (.interruptionEnded(1, shouldResume: true), 40), (.resumeFailed(1, .needsForeground), 41),
      (.foregrounded(turnedOff: false), 50), (.resumed(1), 51), (.idleChanged(1, .pip), 52),
      (.openRequested(inForeground: true), 60), (.closeRequested, 70), (.closed(1), 71),
    ]
    for (event, offset) in steps {
      records += self.records(m.handle(event, now: t0 + offset))
      records += self.records(m.heartbeat(micLive: true, now: t0 + offset))
    }
    return records
  }
}
