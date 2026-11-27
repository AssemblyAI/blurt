@testable import BlurtiOS
@testable import BlurtiOSCore

/// One window over the fakes, with what it asked the coordinator to do
/// (`endings`: the `keepWords` of every `onEndingUtterance`) kept. The window
/// is built, not started: a test that needs the heartbeat calls
/// `window.start()`, as the coordinator's `start()` does.
@MainActor
final class WindowRig {
  let ledger = Ledger()
  let source: FakeListeningSource
  let audio = FakeAudioSession()
  let tasks = FakeBackgroundTasks()
  let idle: FakeIdle
  let clock = TestClock()
  let app = AppStateBox()
  let window: ListeningWindow
  private(set) var endings: [Bool] = []

  /// The last record the window published.
  var state: ListeningState? { window.state }

  /// The window's time: when the rig was built, moved on only by `clock`, so
  /// a timer measured against it sleeps exactly its interval on the clock and
  /// a record's stamps age only when the test steps it.
  var now: Date { window.now() }

  init(
    store: SharedStore, holdsClose: Bool = false, holdsStart: Bool = false, holdsClosing: Bool = false
  ) {
    let fake = FakeListeningSource(holdsClose: holdsClose, holdsStart: holdsStart, ledger: ledger)
    self.source = fake
    idle = FakeIdle(holdsClosing: holdsClosing, ledger: ledger)
    let box = app
    let ticks = clock
    let built = Date()
    window = ListeningWindow(
      store: store,
      source: fake,
      audioSession: audio,
      appState: { box.state },
      backgroundTasks: tasks,
      clock: clock,
      now: { built.addingTimeInterval(ticks.now.offset / .seconds(1)) },
      idle: idle
    )
    window.onEndingUtterance = { [weak self] keepWords in self?.endings.append(keepWords) }
  }

  /// Advances the clock by `duration` once a timer due within `due` of now
  /// has parked on it; false when none parked in time. A timer is a task the
  /// window starts, so the record that announces it can land before its
  /// `sleep` does: advancing then leaves the timer to park after the step,
  /// due a whole interval past it, and the test waits out its `until` for a
  /// tick that never comes. Bounded, as `until` is, since these suites carry
  /// no `.timeLimit` to end an unbounded wait.
  @discardableResult
  func step(_ duration: Duration, once due: ClosedRange<Duration>) async -> Bool {
    let parked = await until { self.clock.sleepingFor.contains { due.contains($0) } }
    clock.advance(by: duration)
    return parked
  }

  /// One heartbeat: the clock stepped by `SharedStore.appHeartbeatInterval`
  /// once the beat's timer has parked a full interval out.
  @discardableResult
  func beat() async -> Bool {
    let interval = Duration.seconds(SharedStore.appHeartbeatInterval)
    return await step(interval, once: interval...interval)
  }

  /// Opens the window in front and waits for the record to say so.
  @discardableResult
  func opened() async -> Bool {
    window.open()
    return await until { self.state?.window == .open }
  }

  /// Opens the window and starts a dictation in it; waits for the record to say so.
  @discardableResult
  func dictating() async -> Bool {
    await opened()
    window.utteranceStarted()
    return await until { self.state?.utterance == true }
  }

  /// A call takes the microphone; waits for the record to say so.
  @discardableResult
  func interrupted() async -> Bool {
    audio.sink.yield(.interruptionBegan)
    return await until { self.state?.window == .interrupted }
  }

  /// Closes the window and waits for the record to say so.
  @discardableResult
  func closed() async -> Bool {
    window.close()
    return await until { self.state?.window == .closed }
  }
}
