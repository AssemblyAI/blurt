import Foundation
import Testing

@testable import BlurtEngine

/// The warm-recorder lifecycle (`MicCapture+Warm`): build ahead of the press,
/// refuse to double-build, and validate against the resolved input (device
/// *and* pin) before reuse.
///
/// Gated on BLURT_LIVE_AUDIO_TESTS=1, like `MicCaptureLevelsTests`, because
/// every test here builds a real `CaptureSessionRecorder` — a live
/// `AVCaptureSession` with a real `AVCaptureDeviceInput`, which needs an input
/// device and the microphone authorization only a human's Mac has. On a
/// headless runner device attachment is at best absent and at worst blocks on
/// a TCC prompt nothing will answer, so the suite documents and locks the warm
/// lifecycle for a human running it locally; `MicCapture+Warm.swift` is
/// excluded from the coverage gate for the same reason `MicCapture.swift` is.
@Suite(
  "MicCapture warm recorder (live)",
  .enabled(
    if: ProcessInfo.processInfo.environment["BLURT_LIVE_AUDIO_TESTS"] == "1",
    "set BLURT_LIVE_AUDIO_TESTS=1 to run (needs a real microphone)"),
  .tags(.liveAudio),
  .timeLimit(.minutes(1)))
struct MicCaptureWarmTests {
  private let builtIn = AudioRoute.InputSnapshot(deviceID: 7, transportType: nil)
  private let airPods = AudioRoute.InputSnapshot(deviceID: 8, transportType: nil)

  @Test("warmUp builds a recorder once; a second call has been overtaken and no-ops")
  func warmUpPreparesOnce() async throws {
    let mic = MicCapture(deviceSelection: { .systemDefault })
    #expect(await mic.canPrepareWarmRecorder)

    await mic.warmUp()
    #expect(await mic.hasWarmRecorder)
    // The slot is taken, so a second build has nothing to do.
    #expect(await mic.canPrepareWarmRecorder == false)

    // A second warm-up — e.g. a scheduled re-warm that lost its race with a
    // launch-time warmUp — must not replace the recorder already built.
    let identity = await mic.warmRecorderIdentity
    await mic.warmUp()
    #expect(await mic.warmRecorderIdentity == identity)

    await mic.discardWarmRecorder()
  }

  @Test("warmUp is refused across the bring-up window, when both recorder slots are nil")
  func warmUpRefusedDuringBringUp() async throws {
    // The regression `bringingUpCapture` exists for: across `start()`'s liveness
    // wait both `activeRecorder` and `warm` are nil, so a guard reading only
    // those would call a live capture "idle" and build a recorder the press is
    // about to race.
    let mic = MicCapture(deviceSelection: { .systemDefault })
    await mic.setBringingUpCapture(true)
    await mic.warmUp()
    #expect(await mic.hasWarmRecorder == false)

    await mic.setBringingUpCapture(false)
    await mic.warmUp()
    #expect(await mic.hasWarmRecorder)

    await mic.discardWarmRecorder()
  }

  @Test("a warm recorder is reused only while still bound to the live resolved input")
  func warmRecorderReusedWhenDeviceUnchanged() async throws {
    let mic = MicCapture(deviceSelection: { .systemDefault })
    try await mic.installWarmRecorder(boundTo: builtIn)

    #expect(await mic.takeWarm(matching: builtIn))
    // Consumed either way — the take empties the slot, so the next press can't
    // double-dip and the re-warm guard sees it as free again.
    #expect(await mic.hasWarmRecorder == false)
    #expect(await mic.canPrepareWarmRecorder)

    // Nothing held: the take answers nil rather than conjuring a recorder.
    #expect(await mic.takeWarm(matching: builtIn) == false)
  }

  @Test("a device change — or an unreadable route on either side — discards the warm recorder")
  func warmRecorderDiscardedOnDeviceChangeOrUnknown() async throws {
    // Reuse requires *positively* confirming the device is unchanged. A recorder
    // bound to the wrong device doesn't fail loudly — it records the wrong mic,
    // or silence — so unknown means discard: rebuilding is the cheaper mistake.
    let mic = MicCapture(deviceSelection: { .systemDefault })

    // The user connected their AirPods after the warm-up.
    try await mic.installWarmRecorder(boundTo: builtIn)
    #expect(await mic.takeWarm(matching: airPods) == false)
    #expect(await mic.hasWarmRecorder == false)

    // The route was unreadable when the recorder was warmed.
    try await mic.installWarmRecorder(boundTo: nil)
    #expect(await mic.takeWarm(matching: builtIn) == false)

    // The route is unreadable now, at press time.
    try await mic.installWarmRecorder(boundTo: builtIn)
    #expect(await mic.takeWarm(matching: nil) == false)
  }

  @Test("a selection change between warm-up and press discards the warm recorder")
  func warmRecorderDiscardedOnPinChange() async throws {
    // The pin is part of the warm recorder's identity, not just the device it
    // resolves to: even when both selections currently resolve to the same
    // device, a recorder warmed un-pinned follows a later default switch where
    // a pinned one must not — so a match on device ID alone would reuse the
    // wrong binding.
    let mic = MicCapture(deviceSelection: { .systemDefault })

    // Warmed while following the system default; the press arrives pinned.
    try await mic.installWarmRecorder(boundTo: builtIn)
    #expect(await mic.takeWarm(matching: builtIn, pinnedUID: "uid:test") == false)

    // Warmed under a pin; the press arrives un-pinned.
    try await mic.installWarmRecorder(boundTo: builtIn, pinnedUID: "uid:test")
    #expect(await mic.takeWarm(matching: builtIn) == false)

    // The same pin on both sides still reuses.
    try await mic.installWarmRecorder(boundTo: builtIn, pinnedUID: "uid:test")
    #expect(await mic.takeWarm(matching: builtIn, pinnedUID: "uid:test"))
  }

  @Test("a scheduled re-warm eventually builds a recorder on its own turn")
  func scheduledRewarmPreparesARecorder() async throws {
    // `stop()`/`cancelCapture()` schedule rather than build inline because the
    // caller sits on a path the user is waiting behind. All this can pin
    // deterministically is the other half of that contract: the scheduled task
    // does land, and builds. Polled on a deadline with a real sleep between
    // reads — the scheduled child task needs a cooperative thread, and a hot
    // spin here competes with the very task it is waiting for; the deadline
    // turns "never landed" into a failed expectation rather than a hang the
    // suite's time limit has to clean up.
    let mic = MicCapture(deviceSelection: { .systemDefault })
    await mic.scheduleRewarm()
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
    while await mic.hasWarmRecorder == false, ContinuousClock().now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await mic.hasWarmRecorder)

    await mic.discardWarmRecorder()
  }
}

/// Actor-isolated test seams over `MicCapture`'s internal warm-recorder state.
/// Extensions because the recorder backend is only `@unchecked Sendable` under
/// the capture path's confinement argument, so neither the `warm` slot nor
/// `takeWarmRecorder`'s return should cross the actor boundary into a test —
/// each helper reduces it to a `Sendable` answer on the actor instead.
extension MicCapture {
  /// Whether a warm recorder is currently held.
  var hasWarmRecorder: Bool { warm != nil }

  /// The held warm recorder's identity, so a test can tell "still the same
  /// recorder" from "quietly replaced" without taking it out of the slot.
  var warmRecorderIdentity: ObjectIdentifier? {
    warm.map { ObjectIdentifier($0.recorder) }
  }

  /// Opens or closes the bring-up window `canPrepareWarmRecorder` guards on,
  /// standing in for a `start()` suspended in its liveness wait (which needs
  /// real hardware to reach).
  func setBringingUpCapture(_ value: Bool) {
    bringingUpCapture = value
  }

  /// Installs a warm recorder bound to a *known* input (and pin) —
  /// `prepareWarmRecorder` with the resolution read replaced by `input` /
  /// `pinnedUID`, so the identity tests don't depend on what the test machine's
  /// routing happens to answer. The recorder itself is a real (idle) session on
  /// the default device; only the recorded identity is synthetic.
  func installWarmRecorder(
    boundTo input: AudioRoute.InputSnapshot?, pinnedUID: String? = nil
  ) throws {
    warm = WarmRecorder(
      recorder: try CaptureSessionRecorder(pinnedUID: nil), input: input, pinnedUID: pinnedUID)
  }

  /// Consumes the warm slot through the production validation, reporting whether
  /// the recorder was reusable. A reused recorder is torn down here, the job
  /// `start()` would otherwise inherit; the discard path already does so.
  func takeWarm(matching input: AudioRoute.InputSnapshot?, pinnedUID: String? = nil) -> Bool {
    let resolved = ResolvedInput(input: input, pinnedUID: pinnedUID)
    guard let recorder = takeWarmRecorder(matching: resolved) else { return false }
    recorder.stopAndDiscard()
    return true
  }

  /// Test teardown: drops the warm recorder. Through `takeWarmRecorder` rather
  /// than a bare `warm = nil`, so teardown can't diverge from how production
  /// empties the slot.
  func discardWarmRecorder() {
    _ = takeWarmRecorder(matching: ResolvedInput(input: nil, pinnedUID: nil))
  }
}
