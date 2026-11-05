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
// window.

/// A microphone that opens, parks, holds and closes on request, and reports
/// through `eventSink` whatever the test says happened to it.
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
  let events: AsyncStream<SourceEvent>
  let eventSink: AsyncStream<SourceEvent>.Continuation

  init(closeDelay: Duration = .zero) {
    self.closeDelay = closeDelay
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
  }

  func start() async throws -> AsyncStream<Data> {
    tally.withLock { $0.started += 1 }
    guard isOpen else { throw BlurtError.audioCaptureFailed(underlying: ListeningSourceFailure.windowClosed) }
    return AsyncStream { $0.finish() }
  }

  func stop() -> Int { 0 }

  func cancelCapture() {}
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

/// A held idle mode that counts its hooks and keeps the source it was given.
@MainActor
final class FakeIdle: IdleMode {
  let kind = ListeningState.Idle.held
  var report: ((IdleReport) -> Void)?
  private(set) var opened = 0
  private(set) var closing = 0
  private(set) var began = 0
  private(set) var ended = 0
  private var source: (any ListeningSource)?

  var isLive: Bool { source?.isOpen ?? false }

  func windowOpened(source: any ListeningSource) async throws {
    self.source = source
    opened += 1
  }

  func utteranceWillBegin() { began += 1 }

  func utteranceDidEnd() { ended += 1 }

  func windowClosing() {
    closing += 1
    source = nil
  }
}

/// The application's state, as the window reads it.
@MainActor
final class AppStateBox {
  var state = UIApplication.State.active
}

/// A clock the test advances by hand: a sleep ends when `advance(by:)` passes
/// its deadline, never on its own, so a heartbeat or an expiry fires when the
/// test says and not a second before.
nonisolated final class ManualClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }

    func duration(to other: Instant) -> Duration { other.offset - offset }

    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let id: UUID
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var sleepers: [Sleeper] = []
  }

  private let state = Mutex(State())

  var now: Instant { state.withLock { $0.now } }
  var minimumResolution: Duration { .zero }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let due = state.withLock { state -> Bool in
          if deadline <= state.now { return true }
          if Task.isCancelled { return true }
          state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
          return false
        }
        if due { continuation.resume() }
      }
    } onCancel: {
      let cancelled = state.withLock { state -> Sleeper? in
        guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
        return state.sleepers.remove(at: index)
      }
      cancelled?.continuation.resume(throwing: CancellationError())
    }
  }

  /// Moves the clock on and wakes every sleep whose deadline has passed.
  func advance(by duration: Duration) {
    let woken = state.withLock { state -> [Sleeper] in
      state.now = state.now.advanced(by: duration)
      let due = state.sleepers.filter { $0.deadline <= state.now }
      state.sleepers.removeAll { $0.deadline <= state.now }
      return due
    }
    for sleeper in woken { sleeper.continuation.resume() }
  }
}

/// One window over the fakes, with what it asked the coordinator to do
/// (`endings`: the `keepWords` of every `onEndingUtterance`) kept.
@MainActor
final class WindowRig {
  let source: FakeListeningSource
  let audio = FakeAudioSession()
  let tasks = FakeBackgroundTasks()
  let idle = FakeIdle()
  let clock = ManualClock()
  let app = AppStateBox()
  let window: ListeningWindow
  private(set) var endings: [Bool] = []

  init(closeDelay: Duration = .zero) {
    let source = FakeListeningSource(closeDelay: closeDelay)
    self.source = source
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

  /// A call takes the microphone; waits for the record to say so.
  @discardableResult
  func interrupted() async -> Bool {
    audio.sink.yield(.interruptionBegan)
    return await until { self.state?.window == .interrupted }
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
