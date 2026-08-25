import Foundation
import Testing

@testable import BlurtEngine

/// The warm-recorder lifecycle (`MicCapture+Warm`): prepare ahead of the press,
/// refuse to double-prepare, validate against the live input before reuse, and
/// tear down on a stale expiry ticket.
///
/// Gated on BLURT_LIVE_AUDIO_TESTS=1, like `MicCaptureLevelsTests`, because every
/// test here goes through `MicCapture.makeRecorder()` — and that calls
/// `prepareToRecord()`, which is *the* route-activation call this whole change is
/// about. On a runner with no input device it is not merely unreliable, it is
/// hostile: it blocks the calling thread rather than suspending, so several of
/// these running concurrently occupy the cooperative pool and wedge the entire
/// `swift test` run, not just this suite. That is not a hypothetical — an
/// ungated first attempt failed three expectations here and then hung 171
/// unrelated tests until the job's 30-minute timeout killed it.
///
/// So this suite documents and locks the warm lifecycle for a human running it
/// on a real Mac with a real microphone; `MicCapture+Warm.swift` is excluded
/// from the coverage gate for the same reason `MicCapture.swift` is.
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

  @Test("warmUp prepares a recorder once; a second call has been overtaken and no-ops")
  func warmUpPreparesOnce() async throws {
    let mic = MicCapture(deviceSelection: { .systemDefault })
    #expect(await mic.canPrepareWarmRecorder)

    await mic.warmUp()
    #expect(await mic.hasWarmRecorder)
    // The slot is taken, so it is no longer safe to open the input for another.
    #expect(await mic.canPrepareWarmRecorder == false)

    // A second warm-up — e.g. a scheduled re-warm that lost its race with a
    // launch-time warmUp — must not stack a second open recorder onto the input.
    let generation = await mic.preparedGeneration
    await mic.warmUp()
    #expect(await mic.preparedGeneration == generation)

    await mic.discardWarmRecorder()
  }

  @Test("warmUp is refused across the bring-up window, when both recorder slots are nil")
  func warmUpRefusedDuringBringUp() async throws {
    // The regression `bringingUpCapture` exists for: across `start()`'s liveness
    // wait both `activeRecorder` and `warm` are nil, so a guard reading only
    // those would call a live capture "idle" and prepare a second recorder onto
    // the already-open input.
    let mic = MicCapture(deviceSelection: { .systemDefault })
    await mic.setBringingUpCapture(true)
    await mic.warmUp()
    #expect(await mic.hasWarmRecorder == false)

    await mic.setBringingUpCapture(false)
    await mic.warmUp()
    #expect(await mic.hasWarmRecorder)

    await mic.discardWarmRecorder()
  }

  @Test("a warm recorder is reused only while still bound to the live default input")
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
    // or silence — so unknown means discard: paying route activation again is
    // the cheaper mistake.
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
    // wrong backend.
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

  @Test("an expiry with a stale generation ticket leaves a later warm recorder alone")
  func staleExpiryTicketDoesNothing() async throws {
    // Cancellation alone doesn't cover this: an expiry already past its
    // cancellation check still gets its actor turn, and without the ticket it
    // would tear down a recorder prepared a moment ago.
    let mic = MicCapture(deviceSelection: { .systemDefault })
    try await mic.installWarmRecorder(boundTo: builtIn)
    let generation = await mic.preparedGeneration

    await mic.releasePreparedRecorder(generation: generation - 1)
    #expect(await mic.hasWarmRecorder)

    // The live ticket is what tears the idle recorder down, freeing the input.
    await mic.releasePreparedRecorder(generation: generation)
    #expect(await mic.hasWarmRecorder == false)
  }

  @Test("a scheduled re-warm eventually prepares a recorder on its own turn")
  func scheduledRewarmPreparesARecorder() async throws {
    // `stop()`/`cancelCapture()` schedule rather than prepare inline because
    // preparing re-opens the input — the slow part — and both sit on paths the
    // user is waiting behind. All this can pin deterministically is the other
    // half of that contract: the scheduled task does land, and prepares.
    // Polled on a deadline with a real sleep between reads, NOT a bare
    // `Task.yield()` spin. `scheduleRewarm` hands the work to a child task that
    // needs a cooperative thread to run on, and `warmUp()` then blocks that
    // thread inside CoreAudio — so a hot spin here competes with the very task
    // it is waiting for, and on a machine where the recorder never materialises
    // it never terminates at all. Sleeping yields the thread outright, and the
    // deadline turns "never landed" into a failed expectation rather than a hang
    // the suite's time limit has to clean up.
    let mic = MicCapture(deviceSelection: { .systemDefault })
    let before = await mic.preparedGeneration
    await mic.scheduleRewarm()
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
    while await mic.preparedGeneration == before, ContinuousClock().now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await mic.hasWarmRecorder)

    await mic.discardWarmRecorder()
  }
}

/// Actor-isolated test seams over `MicCapture`'s internal warm-recorder state.
/// Extensions because the recorder backends are only `@unchecked Sendable`
/// under the capture path's confinement argument, so neither the `warm` slot
/// nor `takeWarmRecorder`'s return should cross the actor boundary into a
/// test — each helper reduces it to a `Sendable` answer on the actor instead.
extension MicCapture {
  /// Whether a warm recorder is currently held.
  var hasWarmRecorder: Bool { warm != nil }

  /// Opens or closes the bring-up window `canPrepareWarmRecorder` guards on,
  /// standing in for a `start()` suspended in its liveness wait (which needs
  /// real hardware to reach).
  func setBringingUpCapture(_ value: Bool) {
    bringingUpCapture = value
  }

  /// Installs a warm recorder bound to a *known* input (and pin) —
  /// `prepareWarmRecorder` with the resolution read replaced by `input` /
  /// `pinnedUID`, so the identity tests don't depend on what the test machine's
  /// routing happens to answer.
  func installWarmRecorder(
    boundTo input: AudioRoute.InputSnapshot?, pinnedUID: String? = nil
  ) throws {
    preparedGeneration += 1
    warm = WarmRecorder(
      recorder: try WAVFileRecorder(), input: input, pinnedUID: pinnedUID,
      generation: preparedGeneration)
  }

  /// Consumes the warm slot through the production validation, reporting whether
  /// the recorder was reusable. A reused recorder's temp file is cleaned up here,
  /// the job `start()` would otherwise inherit; the discard path already does so.
  func takeWarm(matching input: AudioRoute.InputSnapshot?, pinnedUID: String? = nil) -> Bool {
    let resolved = ResolvedInput(input: input, pinnedUID: pinnedUID)
    guard let recorder = takeWarmRecorder(matching: resolved) else { return false }
    recorder.stopAndDiscard()
    return true
  }

  /// Test teardown: drops the warm recorder (and its expiry countdown) so a
  /// finished test doesn't leave a 60 s expiry task holding the suite's actor.
  /// Through `takeWarmRecorder` — which cancels the expiry — rather than a bare
  /// `warm = nil`, so teardown can't diverge from how production empties the slot.
  func discardWarmRecorder() {
    _ = takeWarmRecorder(matching: ResolvedInput(input: nil, pinnedUID: nil))
  }
}
