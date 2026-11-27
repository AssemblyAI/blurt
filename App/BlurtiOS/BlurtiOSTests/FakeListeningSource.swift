import BlurtEngine
import Foundation
import Synchronization

@testable import BlurtiOS

/// A microphone that opens, parks, holds and closes on request, and reports
/// through `eventSink` whatever the test says happened to it. With
/// `holdsStart`, a press's `start()` waits for `releaseStart()`, so the
/// `.connecting` phase lasts until the test has seen it; its `stop()` reports
/// enough audio to transcribe.
nonisolated final class FakeListeningSource: ListeningSource, @unchecked Sendable {
  private struct Tally {
    var opened = 0
    var closed = 0
    var held = 0
    var started = 0
  }

  private let tally = Mutex(Tally())
  private let openFlag = Atomic<Bool>(false)
  /// How long `close()` takes, so a reopen can land while the source is closing.
  private let closeDelay: Duration
  /// Whether a press's `start()` waits for `releaseStart()` before its first
  /// frame. A hold the test lifts rather than a delay: a 200 ms sleep here let
  /// `.connecting` pass before a busy main actor polled for it, and the test
  /// then waited out its whole 30 s for a phase already gone.
  private let holdsStart: Bool
  /// Whether `releaseStart()` has run, and the `start()` parked until it does.
  private let startGate = Mutex<(released: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))
  private let ledger: Ledger
  let events: AsyncStream<SourceEvent>
  let eventSink: AsyncStream<SourceEvent>.Continuation

  var isOpen: Bool { openFlag.load(ordering: .acquiring) }
  var opened: Int { tally.withLock { $0.opened } }
  var closed: Int { tally.withLock { $0.closed } }
  var held: Int { tally.withLock { $0.held } }
  var started: Int { tally.withLock { $0.started } }

  /// No meter: the fake captures nothing to measure.
  var levels: AsyncStream<Float> { AsyncStream { $0.finish() } }

  init(closeDelay: Duration = .zero, holdsStart: Bool = false, ledger: Ledger = Ledger()) {
    self.closeDelay = closeDelay
    self.holdsStart = holdsStart
    self.ledger = ledger
    (events, eventSink) = AsyncStream<SourceEvent>.makeStream()
  }

  /// Lets a held `start()` deliver its first frame, now or whenever it gets
  /// there.
  func releaseStart() {
    let waiter = startGate.withLock { gate in
      gate.released = true
      defer { gate.waiter = nil }
      return gate.waiter
    }
    waiter?.resume()
  }

  /// Taken away or given back, as the window's polls see it.
  func setOpen(_ value: Bool) { openFlag.store(value, ordering: .releasing) }

  func open() {
    tally.withLock { $0.opened += 1 }
    openFlag.store(true, ordering: .releasing)
    ledger.note("source.open")
  }

  /// Parking is the Picture in Picture mode's; the fakes test the held window.
  func park() {
    // Nothing to do: these tests run the held window, which never parks.
  }

  func hold() {
    tally.withLock { $0.held += 1 }
    openFlag.store(true, ordering: .releasing)
  }

  func close() async {
    // wall-clock-ok: a delay the test asks for, modelling a slow close; zero by default
    if closeDelay > .zero { try? await Task.sleep(for: closeDelay) }
    tally.withLock { $0.closed += 1 }
    openFlag.store(false, ordering: .releasing)
    ledger.note("source.close")
  }

  func start() async throws -> AsyncStream<Data> {
    tally.withLock { $0.started += 1 }
    guard isOpen else { throw BlurtError.audioCaptureFailed(underlying: ListeningSourceFailure.windowClosed) }
    if holdsStart {
      await withCheckedContinuation { waiter in
        let released = startGate.withLock { gate in
          if !gate.released {
            gate.waiter = waiter
          }
          return gate.released
        }
        if released { waiter.resume() }
      }
    }
    return AsyncStream { $0.finish() }
  }

  /// Enough for the session to transcribe, so a release runs the pipeline.
  func stop() -> Int { RecordingLimits.minPCMBytes }

  func cancelCapture() {
    // Nothing to release: the fake captures nothing.
  }

  func warmUp() {
    // Nothing to pre-pay: the fake opens no device.
  }
}
