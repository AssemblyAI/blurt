import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// The protocol's default meter, warm-up, and cancel teardown, which let a
/// capture without any of them (test stubs, headless hosts) conform with just
/// `start()`/`stop()`.
@Suite("MicCaptureProtocol defaults")
struct MicCaptureProtocolDefaultsTests {

  /// Supplies only the two required capture calls, so `levels`, `warmUp()` and
  /// `cancelCapture()` resolve to the protocol's defaults.
  /// A `final class` over a `Mutex` rather than a struct (what this stub used to
  /// be) so it can count calls: the protocol's methods are non-mutating, and
  /// `Mutex` is non-copyable, so a struct can't hold one. Same shape as the test
  /// support's `RecordedLog`.
  final class BareMic: MicCaptureProtocol {
    /// Counts the `stop()` calls the defaults route through, so the cancel
    /// default can be observed.
    let stops = Mutex(0)

    func start() async throws {}
    func stop() async throws -> Data {
      stops.withLock { $0 += 1 }
      return Data()
    }
  }

  @Test("default levels stream is empty and finishes immediately; warmUp is a no-op")
  func defaults() async {
    let mic = BareMic()
    // Must return rather than hang or throw — it's fire-and-forget on press.
    await mic.warmUp()

    // The default meter finishes at once, so a for-await over it never blocks
    // a host that reads the meter through the protocol.
    var count = 0
    for await _ in mic.levels { count += 1 }
    #expect(count == 0)
  }

  @Test("default cancelCapture stops and discards")
  func cancelCaptureDefault() async throws {
    // A capture with no cancel-specific teardown must still *end* on a cancel —
    // the default is stop-and-discard, so a conformance that never heard of
    // `cancelCapture` keeps the behavior it had when the session called `stop()`
    // directly. (`MicCapture` overrides it to skip the tail linger and the
    // read-back; that path needs real hardware, so it isn't covered here.)
    let mic = BareMic()
    try await mic.cancelCapture()
    let stops = mic.stops.withLock { $0 }
    #expect(stops == 1)
  }
}
