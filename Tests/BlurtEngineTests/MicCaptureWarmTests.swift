import Testing

@testable import BlurtEngine

/// The warm-recorder lifecycle (`MicCapture+Warm`): prepare ahead of the press,
/// refuse to double-prepare, validate against the live input before reuse, and
/// tear down on a stale expiry ticket.
///
/// Runs without hardware: none of this begins capture — `warmUp()` only
/// constructs and prepares a file-backed recorder, so unlike the capture
/// lifecycle in `MicCapture.swift` (excluded from the coverage gate, exercised
/// by the env-gated `MicCaptureLevelsTests`) the decisions here are reachable in
/// CI. The device-identity checks are driven through
/// `installWarmRecorder(boundTo:)` below rather than `warmUp()` itself, so what
/// the test machine's `AudioRoute.currentInput()` answers never decides a test.
@Suite("MicCapture warm recorder", .timeLimit(.minutes(1)))
struct MicCaptureWarmTests {
  private let builtIn = AudioRoute.InputSnapshot(deviceID: 7, transportType: nil)
  private let airPods = AudioRoute.InputSnapshot(deviceID: 8, transportType: nil)

  @Test("warmUp prepares a recorder once; a second call has been overtaken and no-ops")
  func warmUpPreparesOnce() async throws {
    let mic = MicCapture()
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
    let mic = MicCapture()
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
    let mic = MicCapture()
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
    let mic = MicCapture()

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

  @Test("an expiry with a stale generation ticket leaves a later warm recorder alone")
  func staleExpiryTicketDoesNothing() async throws {
    // Cancellation alone doesn't cover this: an expiry already past its
    // cancellation check still gets its actor turn, and without the ticket it
    // would tear down a recorder prepared a moment ago.
    let mic = MicCapture()
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
    // Condition-waited rather than yield-budgeted (see `awaitCancelRequest`);
    // the suite's time limit turns a re-warm that never lands into a failure.
    let mic = MicCapture()
    let before = await mic.preparedGeneration
    await mic.scheduleRewarm()
    while await mic.preparedGeneration == before { await Task.yield() }
    #expect(await mic.hasWarmRecorder)

    await mic.discardWarmRecorder()
  }
}

/// Actor-isolated test seams over `MicCapture`'s internal warm-recorder state.
/// Extensions because `AVAudioRecorder` is not `Sendable`, so neither the `warm`
/// slot nor `takeWarmRecorder`'s return can cross the actor boundary into a
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

  /// Installs a warm recorder bound to a *known* input — `prepareWarmRecorder`
  /// with the `AudioRoute.currentInput()` read replaced by `input`, so the
  /// device-identity tests don't depend on what the test machine's routing
  /// happens to answer.
  func installWarmRecorder(boundTo input: AudioRoute.InputSnapshot?) throws {
    preparedGeneration += 1
    warm = WarmRecorder(
      recorder: try Self.makeRecorder(), input: input, generation: preparedGeneration)
  }

  /// Consumes the warm slot through the production validation, reporting whether
  /// the recorder was reusable. A reused recorder's temp file is cleaned up here,
  /// the job `start()` would otherwise inherit; the discard path already does so.
  func takeWarm(matching input: AudioRoute.InputSnapshot?) -> Bool {
    guard let recorder = takeWarmRecorder(matching: input) else { return false }
    Self.removeFile(at: recorder.url)
    return true
  }

  /// Test teardown: drops the warm recorder (and its expiry countdown) so a
  /// finished test doesn't leave a 60 s expiry task holding the suite's actor.
  /// Through `takeWarmRecorder` — which cancels the expiry — rather than a bare
  /// `warm = nil`, so teardown can't diverge from how production empties the slot.
  func discardWarmRecorder() {
    _ = takeWarmRecorder(matching: nil)
  }
}
