import Testing

@testable import BlurtEngine

/// The warm-recorder lifecycle (`MicCapture+Warm`): prepare ahead of the press,
/// refuse to double-prepare, validate against the live input before reuse, and
/// tear down on a stale expiry ticket.
///
/// Everything here is driven through the `installWarmRecorder(boundTo:)` seam
/// and direct state setters, never through `prepareWarmRecorder()`. Preparing
/// for real reads `AudioRoute.currentInput()` — a CoreAudio HAL query that needs
/// an input device. On a headless CI runner that read fails or, worse, blocks
/// inside CoreAudio, pinning the cooperative pool and wedging the whole parallel
/// test process (a pinned pool means even the suite's `.timeLimit` never fires).
/// Production `warmUp()` / `scheduleRewarm()` therefore appear below only on
/// their refusal paths, which return before the prepare. The cost is honest:
/// `prepareWarmRecorder()`'s success path is exercised only on hardware.
@Suite("MicCapture warm recorder", .timeLimit(.minutes(1)))
struct MicCaptureWarmTests {
  private let builtIn = AudioRoute.InputSnapshot(deviceID: 7, transportType: nil)
  private let airPods = AudioRoute.InputSnapshot(deviceID: 8, transportType: nil)

  @Test("warmUp refuses while the slot is taken, so a re-warm can't stack a second recorder")
  func warmUpRefusedWhileSlotTaken() async throws {
    let mic = MicCapture()
    #expect(await mic.canPrepareWarmRecorder)

    try await mic.installWarmRecorder(boundTo: builtIn)
    #expect(await mic.hasWarmRecorder)
    // The slot is taken, so it is no longer safe to open the input for another.
    #expect(await mic.canPrepareWarmRecorder == false)

    // A warm-up landing now — e.g. a scheduled re-warm that lost its race with a
    // launch-time warmUp — must not stack a second open recorder onto the input.
    // Safe to call for real: the guard refuses before the device read.
    let generation = await mic.preparedGeneration
    await mic.warmUp()
    #expect(await mic.preparedGeneration == generation)

    // Emptying the slot reopens the guard.
    await mic.discardWarmRecorder()
    #expect(await mic.canPrepareWarmRecorder)
  }

  @Test("warmUp is refused across the bring-up window, when both recorder slots are nil")
  func warmUpRefusedDuringBringUp() async throws {
    // The regression `bringingUpCapture` exists for: across `start()`'s liveness
    // wait both `activeRecorder` and `warm` are nil, so a guard reading only
    // those would call a live capture "idle" and prepare a second recorder onto
    // the already-open input.
    let mic = MicCapture()
    await mic.setBringingUpCapture(true)
    #expect(await mic.canPrepareWarmRecorder == false)
    await mic.warmUp()
    #expect(await mic.hasWarmRecorder == false)

    // Closing the window reopens the guard. Asserted on the guard itself rather
    // than by calling `warmUp()` again — past the guard it prepares for real,
    // which needs an input device (see the suite comment).
    await mic.setBringingUpCapture(false)
    #expect(await mic.canPrepareWarmRecorder)
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

  @Test("arming the expiry attaches a countdown; consuming the recorder cancels it")
  func armingExpiryAttachesCountdown() async throws {
    let mic = MicCapture()
    try await mic.installWarmRecorder(boundTo: builtIn)
    #expect(await mic.hasExpiryCountdown == false)

    let generation = await mic.preparedGeneration
    await mic.armPreparedRecorderExpiry(generation: generation)
    #expect(await mic.hasExpiryCountdown)

    // Re-arming cancels the previous countdown and installs a fresh one rather
    // than leaving two racing tasks against the same recorder.
    await mic.armPreparedRecorderExpiry(generation: generation)
    #expect(await mic.hasExpiryCountdown)

    // The take cancels the countdown along with consuming the recorder, so a
    // consumed recorder's expiry can never fire against its successor.
    #expect(await mic.takeWarm(matching: builtIn))
    #expect(await mic.hasExpiryCountdown == false)
  }

  @Test("a scheduled re-warm that has been overtaken no-ops on its turn")
  func overtakenScheduledRewarmDoesNothing() async throws {
    // `stop()`/`cancelCapture()` schedule rather than prepare inline because
    // preparing re-opens the input — the slow part — and both sit on paths the
    // user is waiting behind. That deferral means a press (here: an installed
    // recorder) can land before the re-warm's turn, and the overtaken task must
    // find the slot taken and do nothing. (The success half of the contract —
    // the scheduled task preparing a fresh recorder — goes through the device
    // read and is only reachable on hardware; see the suite comment.)
    let mic = MicCapture()
    try await mic.installWarmRecorder(boundTo: builtIn)
    let before = await mic.preparedGeneration

    await mic.scheduleRewarm()
    // A deadline-bounded settling window, not a condition wait: the assertion is
    // a negative, so there is nothing to wait *for* — the window just gives the
    // scheduled task actor turns. A regression (a bumped generation) exits
    // early, straight into the failing expectation; the sleep is
    // cancellation-aware so the suite's time limit can still preempt it.
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(500))
    while await mic.preparedGeneration == before, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await mic.preparedGeneration == before)
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

  /// Whether the held warm recorder has an expiry countdown armed.
  var hasExpiryCountdown: Bool { warm?.expiry != nil }

  /// Opens or closes the bring-up window `canPrepareWarmRecorder` guards on,
  /// standing in for a `start()` suspended in its liveness wait (which needs
  /// real hardware to reach).
  func setBringingUpCapture(_ value: Bool) {
    bringingUpCapture = value
  }

  /// Installs a warm recorder bound to a *known* input — `prepareWarmRecorder`
  /// with the `AudioRoute.currentInput()` read replaced by `input`, so no test
  /// depends on what the test machine's routing happens to answer (or on there
  /// being an input device at all).
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
