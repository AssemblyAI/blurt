import BlurtEngine
import Foundation
import Synchronization
import UIKit

@testable import BlurtiOS
@testable import BlurtiOSCore

// MARK: - The window's collaborators, faked
//
// Everything the interpreter is injected with: a source that does what it is
// told and counts it, an audio session and background tasks that count too,
// an idle mode that reports what it is asked, the application's state as a
// box, and a clock the test advances by hand. `WindowRig` wires them into one
// window. A `Ledger` the source and the idle mode both write to says in what
// order the window asked them.

/// What happened, in order, across the fakes: one line per call, from any thread.
nonisolated final class Ledger: Sendable {
  private let entries = Mutex<[String]>([])

  func note(_ line: String) { entries.withLock { $0.append(line) } }

  var lines: [String] { entries.withLock { $0 } }
}

/// A microphone that opens, parks, holds and closes on request, and reports
/// through `eventSink` whatever the test says happened to it. A press's
/// `start()` holds for `startDelay`, so the `.connecting` phase can be seen;
/// its `stop()` reports enough audio to transcribe.
nonisolated final class FakeListeningSource: ListeningSource, @unchecked Sendable {
  private struct Tally {
    var opened = 0
    var closed = 0
    var held = 0
    var started = 0
  }

  private let tally = Mutex(Tally())
  private let open = Atomic<Bool>(false)
  /// How long `close()` takes, so a reopen can land while the source is closing.
  private let closeDelay: Duration
  /// How long a press's `start()` takes to deliver its first frame.
  private let startDelay: Duration
  private let ledger: Ledger
  let events: AsyncStream<SourceEvent>
  let eventSink: AsyncStream<SourceEvent>.Continuation

  init(closeDelay: Duration = .zero, startDelay: Duration = .zero, ledger: Ledger = Ledger()) {
    self.closeDelay = closeDelay
    self.startDelay = startDelay
    self.ledger = ledger
    (events, eventSink) = AsyncStream<SourceEvent>.makeStream()
  }

  var isOpen: Bool { open.load(ordering: .acquiring) }
  var opened: Int { tally.withLock { $0.opened } }
  var closed: Int { tally.withLock { $0.closed } }
  var held: Int { tally.withLock { $0.held } }
  var started: Int { tally.withLock { $0.started } }

  /// Taken away or given back, as the window's polls see it.
  func setOpen(_ value: Bool) { open.store(value, ordering: .releasing) }

  func open() async throws {
    tally.withLock { $0.opened += 1 }
    open.store(true, ordering: .releasing)
    ledger.note("source.open")
  }

  /// Parking is the Picture in Picture mode's; the fakes test the held window.
  func park() async {}

  func hold() async throws {
    tally.withLock { $0.held += 1 }
    open.store(true, ordering: .releasing)
  }

  func close() async {
    if closeDelay > .zero { try? await Task.sleep(for: closeDelay) }
    tally.withLock { $0.closed += 1 }
    open.store(false, ordering: .releasing)
    ledger.note("source.close")
  }

  func start() async throws -> AsyncStream<Data> {
    tally.withLock { $0.started += 1 }
    guard isOpen else { throw BlurtError.audioCaptureFailed(underlying: ListeningSourceFailure.windowClosed) }
    if startDelay > .zero { try await Task.sleep(for: startDelay) }
    return AsyncStream { $0.finish() }
  }

  /// Enough for the session to transcribe, so a release runs the pipeline.
  func stop() -> Int { SyncSTTLimits.minPCMBytes }

  func cancelCapture() {}
}

/// A transcriber that answers every utterance with the same words, offline.
nonisolated struct StubTranscriber: TranscriberProtocol {
  let text: String

  func transcribe(frames: AsyncStream<Data>, sampleRate: Int, context: TranscriptionContext?) async throws -> String {
    for await _ in frames {}
    return text
  }
}

/// An audio session that counts what the window does to it and says what the
/// test tells it to (`sink`).
@MainActor
final class FakeAudioSession: AudioSessionControlling {
  private(set) var activated = 0
  private(set) var deactivated = 0
  private(set) var preferredApplied = 0
  let events: AsyncStream<AudioSessionEvent>
  let sink: AsyncStream<AudioSessionEvent>.Continuation

  init() {
    (events, sink) = AsyncStream<AudioSessionEvent>.makeStream()
  }

  func activate() throws { activated += 1 }

  func deactivate() throws { deactivated += 1 }

  func applyPreferredInput() { preferredApplied += 1 }
}

/// Background tasks as a ledger: what was begun and what was ended, by name.
@MainActor
final class FakeBackgroundTasks: BackgroundTasking {
  private(set) var begun: [String] = []
  private(set) var ended: [String] = []

  func begin(_ name: String) { begun.append(name) }

  func end(_ name: String) { ended.append(name) }
}

/// A held idle mode that counts its hooks, keeps the source and the
/// generation it was given, and takes `closingDelay` to let go — as a keeper
/// on its way out would.
@MainActor
final class FakeIdle: IdleMode {
  let kind = ListeningState.Idle.held
  var report: ((IdleReport, ListeningWindowMachine.Generation) -> Void)?
  private(set) var opened = 0
  private(set) var closing = 0
  /// `windowClosing` calls that have returned.
  private(set) var closed = 0
  private(set) var began = 0
  private(set) var ended = 0
  /// The window this mode was last armed for.
  private(set) var generation: ListeningWindowMachine.Generation = 0
  private let closingDelay: Duration
  private let ledger: Ledger
  private var source: (any ListeningSource)?

  init(closingDelay: Duration = .zero, ledger: Ledger = Ledger()) {
    self.closingDelay = closingDelay
    self.ledger = ledger
  }

  var isLive: Bool { source?.isOpen ?? false }

  func windowOpened(source: any ListeningSource, generation: ListeningWindowMachine.Generation) async throws {
    self.source = source
    self.generation = generation
    opened += 1
  }

  func utteranceWillBegin() { began += 1 }

  func utteranceDidEnd() { ended += 1 }

  func windowClosing() async {
    closing += 1
    ledger.note("idle.closing")
    source = nil
    if closingDelay > .zero { try? await Task.sleep(for: closingDelay) }
    closed += 1
    ledger.note("idle.closed")
  }
}

/// The application's state, as the window reads it.
@MainActor
final class AppStateBox {
  var state = UIApplication.State.active
}

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

  init(closeDelay: Duration = .zero, startDelay: Duration = .zero, closingDelay: Duration = .zero) {
    let source = FakeListeningSource(closeDelay: closeDelay, startDelay: startDelay, ledger: ledger)
    self.source = source
    idle = FakeIdle(closingDelay: closingDelay, ledger: ledger)
    let app = app
    window = ListeningWindow(
      source: source, audioSession: audio, appState: { app.state }, backgroundTasks: tasks, clock: clock, idle: idle)
    window.onEndingUtterance = { [weak self] keepWords in self?.endings.append(keepWords) }
  }

  /// The last record the window published.
  var state: ListeningState? { window.state }

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

/// Polls until `condition` holds or `timeout` passes; true when it held.
@MainActor
func until(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}
