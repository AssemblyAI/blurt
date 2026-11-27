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
  /// The window's clock, and the one a press's `startDelay` runs on.
  let clock: TestClock
  let app = AppStateBox()
  let window: ListeningWindow
  private(set) var endings: [Bool] = []

  /// The last record the window published.
  var state: ListeningState? { window.state }

  init(
    store: SharedStore, closeDelay: Duration = .zero, startDelay: Duration = .zero, closingDelay: Duration = .zero
  ) {
    let virtualClock = TestClock()
    clock = virtualClock
    let fake = FakeListeningSource(
      closeDelay: closeDelay, startDelay: startDelay, clock: virtualClock, ledger: ledger
    )
    self.source = fake
    idle = FakeIdle(closingDelay: closingDelay, ledger: ledger)
    let box = app
    window = ListeningWindow(
      store: store,
      source: fake,
      audioSession: audio,
      appState: { box.state },
      backgroundTasks: tasks,
      clock: virtualClock,
      idle: idle
    )
    window.onEndingUtterance = { [weak self] keepWords in self?.endings.append(keepWords) }
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
