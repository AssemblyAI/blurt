import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// The pure half of `MicCapture.start()`'s liveness gate: the transport-aware
/// wait cap and the poll-until-the-recorder's-clock-advances loop. Driven
/// against `TestClock` so the Bluetooth cap is exercised without waiting real
/// seconds.
@Suite("MicLiveness", .timeLimit(.minutes(1)))
struct MicLivenessTests {
  @Test("Bluetooth transports get the long cap; everything else the short one")
  func transportTimeouts() {
    // The A2DP→HFP switch is the whole reason the gate exists — both Bluetooth
    // transport types must get the multi-second budget.
    #expect(
      MicLiveness.timeout(forTransportType: kAudioDeviceTransportTypeBluetooth)
        == MicLiveness.bluetoothTimeout)
    #expect(
      MicLiveness.timeout(forTransportType: kAudioDeviceTransportTypeBluetoothLE)
        == MicLiveness.bluetoothTimeout)
    // Wired/built-in inputs deliver frames near-instantly; a long cap there
    // would make a genuinely broken mic feel like a hang.
    #expect(
      MicLiveness.timeout(forTransportType: kAudioDeviceTransportTypeBuiltIn)
        == MicLiveness.defaultTimeout)
    #expect(
      MicLiveness.timeout(forTransportType: kAudioDeviceTransportTypeUSB)
        == MicLiveness.defaultTimeout)
    // An unreadable transport must not be treated as Bluetooth.
    #expect(MicLiveness.timeout(forTransportType: nil) == MicLiveness.defaultTimeout)
  }

  @Test("already-advancing recorder clock confirms immediately, without sleeping")
  func immediateLiveness() async {
    let clock = TestClock()
    // Never advanced: a sleep would park forever, so returning at all proves
    // the fast path never sleeps (the suite's time limit backs that up).
    let gap = await MicLiveness.waitUntilLive(timeout: .seconds(1), clock: clock) { 0.1 }
    #expect(gap == .zero)
  }

  @Test("a clock that advances after a few polls confirms with the elapsed gap")
  func livenessAfterPolls() async {
    let clock = TestClock()
    let polls = Mutex(0)
    async let gap = MicLiveness.waitUntilLive(timeout: MicLiveness.bluetoothTimeout, clock: clock) {
      // Stuck at 0 for the first two checks — the route still switching — then
      // the recorder clock starts moving.
      polls.withLock { polls in
        polls += 1
        return polls < 3 ? 0 : 0.05
      }
    }
    for _ in 1...2 {
      await clock.waitUntilSleeping(for: MicLiveness.pollInterval)
      clock.advance(by: MicLiveness.pollInterval)
    }
    #expect(await gap == MicLiveness.pollInterval * 2)
  }

  @Test("a clock that never advances times out with nil — the fail-open signal")
  func timeoutFailsOpen() async {
    let clock = TestClock()
    let timeout = MicLiveness.pollInterval * 2
    async let gap = MicLiveness.waitUntilLive(timeout: timeout, clock: clock) { 0 }
    for _ in 1...2 {
      await clock.waitUntilSleeping(for: MicLiveness.pollInterval)
      clock.advance(by: MicLiveness.pollInterval)
    }
    #expect(await gap == nil)
  }
}
