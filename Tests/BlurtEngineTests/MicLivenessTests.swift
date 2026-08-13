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
    // The profile switch is the whole reason the gate exists — both Bluetooth
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
    // nil is what tells `MicCapture` to proceed anyway: a silent or broken mic
    // must degrade to the pre-gate behavior, never brick the press.
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

/// The transport classification both the liveness cap and `MicCapture`'s tail
/// linger hang off. Pure and pinned here because `AudioRoute`, which reads the
/// raw value, needs real hardware and is excluded from the coverage gate — so
/// this is the only place the decision can be tested.
@Suite("AudioTransport")
struct AudioTransportTests {
  @Test("both Bluetooth transport types count")
  func bluetoothTransports() {
    #expect(AudioTransport.isBluetooth(kAudioDeviceTransportTypeBluetooth))
    #expect(AudioTransport.isBluetooth(kAudioDeviceTransportTypeBluetoothLE))
  }

  @Test("the tail linger is Bluetooth-only")
  func tailLinger() {
    // The other transport-conditional policy, here rather than in `MicCapture`
    // so it is reachable by `swift test` at all — the capture actor needs real
    // hardware and is excluded from the coverage gate.
    #expect(
      AudioTransport.tailLinger(forTransportType: kAudioDeviceTransportTypeBluetooth)
        == AudioTransport.bluetoothTailLinger)
    // `.zero`, not a small duration: `stop()` skips the sleep entirely on a
    // wired input rather than awaiting a nominal one.
    #expect(AudioTransport.tailLinger(forTransportType: kAudioDeviceTransportTypeBuiltIn) == .zero)
    #expect(AudioTransport.tailLinger(forTransportType: nil) == .zero)
  }

  @Test("wired, built-in, and unreadable transports do not")
  func nonBluetoothTransports() {
    #expect(!AudioTransport.isBluetooth(kAudioDeviceTransportTypeBuiltIn))
    #expect(!AudioTransport.isBluetooth(kAudioDeviceTransportTypeUSB))
    #expect(!AudioTransport.isBluetooth(kAudioDeviceTransportTypeAggregate))
    // nil is the conservative answer for both consumers: the short wait cap and
    // no tail linger. Padding every wired capture with a delay would be a worse
    // regression than losing the tail on a device we couldn't classify.
    #expect(!AudioTransport.isBluetooth(nil))
  }
}

/// `Duration.milliseconds` backs the latency lines `MicCapture` logs for the
/// liveness gap — the field evidence for whether the gate is doing anything —
/// so a silently wrong conversion would make those logs lie.
@Suite("Duration.milliseconds")
struct DurationMillisecondsTests {
  @Test func convertsWholeAndFractionalDurations() {
    #expect(Duration.milliseconds(250).milliseconds == 250)
    #expect(Duration.seconds(2).milliseconds == 2000)
    #expect(Duration.zero.milliseconds == 0)
    // Sub-millisecond durations keep their fraction rather than truncating to 0.
    #expect(Duration.microseconds(500).milliseconds == 0.5)
  }
}
