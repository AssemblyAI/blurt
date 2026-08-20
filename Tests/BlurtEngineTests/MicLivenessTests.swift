import CoreAudio
import Foundation
import Synchronization
import Testing

@testable import BlurtEngine

/// What a live input reads even with nobody talking: a mic's own self-noise sits
/// far above `MicLiveness.silenceFloorDB` (one least-significant bit of a 16-bit
/// sample is already about -90 dBFS). The floor separates *digital* silence from
/// any analog input, so this is what a quiet room must look like — live.
private let quietRoomPowerDB: Float = -90

/// What a zero-filled buffer from a device that hasn't finished switching reads.
private let digitalSilencePowerDB: Float = -160

/// The pure half of `MicCapture.start()`'s liveness gate: the transport-aware
/// wait cap and the poll-until-the-recorder-is-clocking-*and*-metering loop. Driven
/// against `TestClock` so the Bluetooth cap is exercised without waiting real
/// seconds.
@Suite("MicLiveness", .timeLimit(.minutes(1)))
struct MicLivenessTests {
  @Test("each transport class gets its own cap: Bluetooth, local, unclassifiable")
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
    // Every other local transport takes the same budget — the whole set is
    // asserted in `AudioTransportTests.localTransports`.
    #expect(
      MicLiveness.timeout(forTransportType: kAudioDeviceTransportTypeThunderbolt)
        == MicLiveness.defaultTimeout)
    // An aggregate or virtual input, an unnamed type, and an unreadable read all
    // take the middle cap rather than the wired one: the wrapper reports its own
    // transport, so real AirPods can be switching underneath it, and 300 ms
    // cannot cover that. (This is the assertion that read `defaultTimeout` for
    // nil before — the second half of the lost-first-words bug.)
    #expect(
      MicLiveness.timeout(forTransportType: kAudioDeviceTransportTypeAggregate)
        == MicLiveness.unknownTransportTimeout)
    #expect(
      MicLiveness.timeout(forTransportType: kAudioDeviceTransportTypeVirtual)
        == MicLiveness.unknownTransportTimeout)
    #expect(
      MicLiveness.timeout(forTransportType: kAudioDeviceTransportTypeUnknown)
        == MicLiveness.unknownTransportTimeout)
    #expect(MicLiveness.timeout(forTransportType: nil) == MicLiveness.unknownTransportTimeout)
    // It has to sit strictly between the two caps it splits, or it is just one of
    // them under a second name.
    #expect(MicLiveness.defaultTimeout < MicLiveness.unknownTransportTimeout)
    #expect(MicLiveness.unknownTransportTimeout < MicLiveness.bluetoothTimeout)
  }

  @Test("already-advancing recorder clock confirms immediately, without sleeping")
  func immediateLiveness() async {
    let clock = TestClock()
    // Never advanced: a sleep would park forever, so returning at all proves
    // the fast path never sleeps (the suite's time limit backs that up).
    let gap = await MicLiveness.waitUntilLive(
      timeout: .seconds(1), clock: clock, currentTime: { 0.1 },
      inputPowerDB: { quietRoomPowerDB })
    #expect(gap == .zero)
  }

  @Test("the poll interval doubles, so a slow bring-up isn't hundreds of wakeups")
  func livenessBacksOff() async {
    let clock = TestClock()
    let polls = Mutex(0)
    async let gap = MicLiveness.waitUntilLive(
      timeout: MicLiveness.bluetoothTimeout, clock: clock,
      currentTime: {
        // Stuck at 0 for the first three checks — the route still switching —
        // then the recorder clock starts moving.
        polls.withLock { polls in
          polls += 1
          return polls < 4 ? 0 : 0.05
        }
      }, inputPowerDB: { quietRoomPowerDB })
    // Each wait is twice the last: 1 ms, 2 ms, 4 ms. Driving the clock by the
    // exact expected delay is also the assertion — `waitUntilSleeping` matches on
    // the deadline, so a loop that slept a fixed quantum would hang here rather
    // than quietly pass.
    var expected = MicLiveness.initialPollInterval
    var elapsed = Duration.zero
    for _ in 1...3 {
      await clock.waitUntilSleeping(for: expected)
      clock.advance(by: expected)
      elapsed += expected
      expected = min(expected * 2, MicLiveness.maxPollInterval)
    }
    #expect(await gap == elapsed)
  }

  @Test("the backoff is capped rather than doubling without limit")
  func backoffIsCapped() async {
    // Otherwise a 2.5 s Bluetooth cap would end in multi-second sleeps and
    // overshoot the deadline it is supposed to respect.
    let clock = TestClock()
    let polls = Mutex(0)
    async let gap = MicLiveness.waitUntilLive(
      timeout: .seconds(30), clock: clock,
      currentTime: {
        polls.withLock { polls in
          polls += 1
          return polls < 12 ? 0 : 0.05
        }
      }, inputPowerDB: { quietRoomPowerDB })
    var expected = MicLiveness.initialPollInterval
    for _ in 1...11 {
      await clock.waitUntilSleeping(for: expected)
      clock.advance(by: expected)
      expected = min(expected * 2, MicLiveness.maxPollInterval)
    }
    #expect(expected == MicLiveness.maxPollInterval)
    #expect(await gap != nil)
  }

  @Test("a clock advancing over digital silence is not live — the shipped bug")
  func zeroFilledBuffersAreNotLive() async {
    // The gate's original signal was `currentTime > 0` alone, and macOS can hand
    // a stale or not-yet-switched device's queue all-zero buffers (the same
    // failure that retired the `AVAudioEngine` capture path). Frames of digital
    // silence advance the recorder's clock exactly like real audio, so the wait
    // was satisfied on the first ~1 ms poll while the AirPods link was still
    // renegotiating: the "Connecting…" pill flashed past and the start chime
    // fired over a dead mic. With the power term the wait holds instead.
    #expect(await waitToCap(powerDB: { digitalSilencePowerDB }) == nil)
  }

  @Test("the floor is exclusive, and a non-finite reading is not live either")
  func silenceFloorEdges() async {
    // At the floor, not above it.
    #expect(await waitToCap(powerDB: { MicLiveness.silenceFloorDB }) == nil)
    // NaN fails both comparisons; -infinity is what a truly muted device can
    // report. Both must read as not-live, so they land on the fail-open path
    // rather than confirming a route that is delivering nothing.
    #expect(await waitToCap(powerDB: { Float.nan }) == nil)
    #expect(await waitToCap(powerDB: { -Float.infinity }) == nil)
  }

  @Test("an advancing clock plus real input power confirms at once")
  func realInputPowerConfirmsPromptly() async {
    // The other half of the floor's job: it must not become voice-activity
    // detection. A live mic in a silent room reads its own self-noise, well above
    // the floor, so a user who presses and says nothing is confirmed immediately
    // instead of waiting out the cap — no grace period needed. The clock is never
    // advanced here, so a sleep would park forever and the suite's time limit
    // would fail this rather than let it pass slowly.
    let clock = TestClock()
    let gap = await MicLiveness.waitUntilLive(
      timeout: MicLiveness.bluetoothTimeout, clock: clock, currentTime: { 0.05 },
      inputPowerDB: { quietRoomPowerDB })
    #expect(gap == .zero)
  }

  @Test("the gate's log line carries the transport, the wait, and the meter")
  func logSummaryCarriesTheDiagnosis() {
    // This line is the field evidence for the zero-buffer premise, which can't be
    // reproduced without a Mac and AirPods — so what it must contain is pinned
    // here rather than left to an untested call site in `MicCapture`.
    let confirmed = MicLiveness.logSummary(
      gap: .milliseconds(1420), timeout: MicLiveness.bluetoothTimeout,
      transportType: kAudioDeviceTransportTypeBluetooth, powerDB: -37.5)
    #expect(confirmed.contains("live after 1420 ms"))
    #expect(confirmed.contains("transport=\(kAudioDeviceTransportTypeBluetooth)"))
    #expect(confirmed.contains("powerDB=-37.5"))

    // Fail-open reports the cap it waited out. An unreadable transport has to
    // stay distinguishable from `kAudioDeviceTransportTypeUnknown`, which is 0.
    let failedOpen = MicLiveness.logSummary(
      gap: nil, timeout: MicLiveness.unknownTransportTimeout, transportType: nil,
      powerDB: digitalSilencePowerDB)
    #expect(failedOpen.contains("unconfirmed after 1000 ms"))
    #expect(failedOpen.contains("transport=nil"))
    #expect(failedOpen.contains("powerDB=-160.0"))
  }

  @Test("a clock that never advances times out with nil — the fail-open signal")
  func timeoutFailsOpen() async {
    // nil is what tells `MicCapture` to proceed anyway: a silent or broken mic
    // must degrade to the pre-gate behavior, never brick the press.
    let clock = TestClock()
    let timeout = MicLiveness.initialPollInterval * 3
    async let gap = MicLiveness.waitUntilLive(
      timeout: timeout, clock: clock, currentTime: { 0 },
      inputPowerDB: { digitalSilencePowerDB })
    var expected = MicLiveness.initialPollInterval
    for _ in 1...2 {
      await clock.waitUntilSleeping(for: expected)
      clock.advance(by: expected)
      expected = min(expected * 2, MicLiveness.maxPollInterval)
    }
    #expect(await gap == nil)
  }

  /// Drives the wait to its cap against a clock this test owns, for a power probe
  /// that never reports live while the recorder's clock is already advancing.
  /// Shared so each "not live" reading is one assertion rather than a copy of the
  /// backoff-driving loop.
  private func waitToCap(powerDB: @escaping @Sendable () -> Float) async -> Duration? {
    let clock = TestClock()
    let timeout = MicLiveness.initialPollInterval * 3
    async let gap = MicLiveness.waitUntilLive(
      timeout: timeout, clock: clock, currentTime: { 0.05 }, inputPowerDB: powerDB)
    var expected = MicLiveness.initialPollInterval
    for _ in 1...2 {
      await clock.waitUntilSleeping(for: expected)
      clock.advance(by: expected)
      expected = min(expected * 2, MicLiveness.maxPollInterval)
    }
    return await gap
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

  @Test("every wired and on-board transport counts as local")
  func localTransports() {
    // Each constant asserted individually: `isLocal` is a switch over all of
    // them, and a value that only matches the first pattern never executes the
    // rest — so this is also what keeps those lines covered.
    #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeBuiltIn))
    #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeUSB))
    #expect(AudioTransport.isLocal(kAudioDeviceTransportTypePCI))
    #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeFireWire))
    #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeThunderbolt))
    #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeDisplayPort))
    #expect(AudioTransport.isLocal(kAudioDeviceTransportTypeHDMI))
  }

  @Test("Bluetooth, wrapped, unnamed and unreadable transports are not local")
  func nonLocalTransports() {
    // `isLocal` is deliberately not `!isBluetooth`: these all fall through to
    // `MicLiveness.unknownTransportTimeout`, because an aggregate or virtual
    // device reports its own transport while real AirPods switch underneath it.
    #expect(!AudioTransport.isLocal(kAudioDeviceTransportTypeAggregate))
    #expect(!AudioTransport.isLocal(kAudioDeviceTransportTypeVirtual))
    #expect(!AudioTransport.isLocal(kAudioDeviceTransportTypeUnknown))
    #expect(!AudioTransport.isLocal(kAudioDeviceTransportTypeBluetooth))
    #expect(!AudioTransport.isLocal(nil))
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
