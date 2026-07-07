import Foundation
import Testing

@testable import BlurtEngine

/// The protocol's default meter and warm-up, which let a capture without either
/// (test stubs, headless hosts) conform with just `start()`/`stop()`.
@Suite("MicCaptureProtocol defaults")
struct MicCaptureProtocolDefaultsTests {

  /// Supplies only the two required capture calls, so `levels` and `warmUp()`
  /// resolve to the protocol's defaults.
  struct BareMic: MicCaptureProtocol {
    func start() async throws {}
    func stop() async throws -> Data { Data() }
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
}
