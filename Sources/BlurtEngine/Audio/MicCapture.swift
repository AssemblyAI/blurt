import Foundation
import os

/// Captures mic audio as the 16 kHz / mono / 16-bit PCM the dictation API wants
/// — so there's no manual tap, resample pass, or PCM plumbing here. Each
/// session uses a freshly built recorder (`CaptureRecorder`, backed by
/// `CaptureSessionRecorder`): an `AVCaptureSession` around the *current*
/// resolution of the user's selection — the device pinned in Settings
/// (`MicDeviceSelection`), or the system default input. The fresh recorder per
/// session is the whole reason this is not a long-lived engine graph: that
/// graph bound its input to one device and went stale on a device switch,
/// raising `-10868` or quietly capturing all-zero buffers; per-session
/// recorders can't go stale.
public actor MicCapture: MicCaptureProtocol {
  // Subsystem/category make these lines findable via:
  //   log show --predicate 'subsystem == "dev.alex.blurt"' --last 1h
  // Stderr is unreachable for .app bundles launched via Finder/LaunchServices,
  // so go through the unified logging system instead.
  static let logger = HostIdentity.current.logger("MicCapture")

  public nonisolated let levels: AsyncStream<Float>
  private nonisolated let levelsContinuation: AsyncStream<Float>.Continuation

  /// Reads the persisted microphone selection, once per session bring-up (and
  /// per warm-up). A closure so tests inject a fixed selection instead of the
  /// process defaults; production reads `MicDeviceStore` per capture, so a
  /// Settings change applies to the very next press — the same re-read-per-use
  /// rule as the key terms.
  let deviceSelection: @Sendable () -> MicDeviceSelection

  /// A recorder built ahead of the press so `start()` doesn't pay session
  /// construction on the hot path, together with the input identity it was
  /// built against. Building does **not** engage the microphone — the device
  /// only opens at `record()` — so holding one idle costs nothing, needs no
  /// expiry, and never shows an input indicator. (Route activation itself is
  /// paid by `record()`'s `startRunning()`, inside the connecting window the
  /// liveness gate already covers.)
  ///
  /// Filled by `warmUp()` at launch and **re-filled after every capture** (see
  /// `scheduleRewarm`). Still a *fresh recorder per session*, which is the
  /// invariant the long-lived-graph revert bought: the warm recorder is
  /// validated against the live resolved input before it is used
  /// (`takeWarmRecorder`) and discarded rather than reused when the device or
  /// the selection has changed underneath it.
  var warm: WarmRecorder?

  /// A built-but-not-started recorder and the identity that only makes sense
  /// alongside it.
  struct WarmRecorder {
    let recorder: any CaptureRecorder
    /// The input it was built against. A recorder attaches its device once, at
    /// build time, and never re-resolves — so without this a recorder warmed
    /// while the built-in mic was default would keep recording from it after
    /// the user connected their AirPods. See `AudioRoute.InputSnapshot.deviceID`
    /// for why identity is the device ID.
    let input: AudioRoute.InputSnapshot?
    /// The device UID the recorder was pinned to, or nil for the system
    /// default. Matched alongside the device identity in `takeWarmRecorder`: a
    /// recorder warmed under one selection must not serve a press made under
    /// another, even when both currently resolve to the same device.
    let pinnedUID: String?
  }

  /// The recorder for the in-flight session; nil between `stop()` and `start()`.
  var activeRecorder: (any CaptureRecorder)?
  /// The in-flight session's input transport, sampled once at `start()`. Read by
  /// `stop()` to size the tail linger — sampled at start rather than re-read at
  /// stop so a device switch mid-utterance can't make the two halves of one
  /// capture disagree.
  private var activeTransportType: UInt32?

  /// Incremented by every `stop()` / `cancelCapture()`. `start()` snapshots it
  /// before suspending in the liveness wait — its one internal suspension — and
  /// re-checks after, so a teardown that interleaves during the wait wins.
  /// Without it, a reentrant caller's stop saw `activeRecorder == nil`, returned
  /// an empty "clean stop", and the not-yet-installed recorder kept capturing
  /// (mic indicator hot) until `start()` resumed. Unreachable
  /// through `DictationSession` — its serial command queue runs release/cancel
  /// only after the press turn completes — but this is a public actor, and any
  /// host can call it unqueued.
  private var stopGeneration = 0

  /// True from `record()` succeeding until the capture is installed or torn
  /// down — i.e. across the liveness wait.
  ///
  /// Needed because during that window **both** recorder slots are nil:
  /// `activeRecorder` isn't installed until the wait returns (the recorder stays
  /// confined to `start()` so nothing can touch it while the poll loop reads its
  /// clock off-actor), and `warm` was consumed on the way in. Without this,
  /// `warmUp()` — which every re-warm goes through — reads those two nils as "no
  /// capture in flight" and prepares a *second* recorder onto the already-live
  /// input, which is very reachable since `stop()` schedules a re-warm that can
  /// land inside the next press's bring-up.
  var bringingUpCapture = false

  /// Polls the active recorder's meter and feeds `levels` while recording.
  private var meterTask: Task<Void, Never>?
  /// The last value `emitLevel` put on the stream, so an unchanged tick can be
  /// dropped. Reset per capture in `start()` — a fresh recording must emit its
  /// first level even when it matches where the previous one left off.
  private var lastEmittedLevel: Float?
  /// How often the meter is sampled for the overlay, in seconds. 20 Hz reads as
  /// smooth for a voice-level meter while cutting the per-tick work (recorder poll
  /// + stream yield, and the SwiftUI bar redraw it drives) by a third versus 30 Hz.
  ///
  /// Public, and the single definition: the pill's continuous animations cap their
  /// redraw to this cadence because the level feed can't show anything faster, so
  /// the view reads it here rather than restating `1.0 / 20.0` behind a comment
  /// claiming the two match — a coupling nothing enforced, which a change here
  /// would silently break, leaving the view under-sampling frames the meter is
  /// paying to produce.
  public static let meterIntervalSeconds: Double = 0.05

  /// `meterIntervalSeconds` as the `Duration` the meter task sleeps for.
  private static let meterInterval = Duration.seconds(meterIntervalSeconds)

  public init(
    deviceSelection: @escaping @Sendable () -> MicDeviceSelection = { MicDeviceStore().selection }
  ) {
    self.deviceSelection = deviceSelection
    // The continuation is fed from a ~20 Hz meter timer; the levels stream is a
    // meter, not the captured signal — the consumer only renders the most recent
    // value — so cap it at the newest single element.
    let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.levels = stream
    self.levelsContinuation = continuation
  }

  public func start() async throws {
    // One trip through CoreAudio per session, answering every question this
    // capture has about its input: which device the selection resolves to
    // (pinned, or the system default — including the missing-pin fallback),
    // whether the warm recorder is still bound to it, and whether its link
    // buffers a tail worth waiting for at stop.
    let resolved = Self.resolveInput(selection: deviceSelection())
    // Reuse the warm recorder when it is still bound to the resolved input;
    // otherwise build a fresh one. `??` only evaluates `makeBackend` when
    // nothing usable was warmed.
    let recorder =
      try takeWarmRecorder(matching: resolved)
      ?? Self.makeBackend(pinnedUID: resolved.pinnedUID)

    // record() returns false when no usable input device is available (unplugged,
    // asleep, route lost). Surface that as a thrown Swift error so
    // DictationSession.press() reports `.audioCaptureFailed` instead of recording
    // nothing. (No path here can raise an uncatchable Obj-C exception, so there's
    // no degenerate-format guard to keep.)
    guard recorder.record() else {
      Self.logger.error("recorder.record() returned false — no usable input device")
      recorder.stopAndDiscard()
      throw BlurtError.audioCaptureFailed(underlying: MicCaptureError.noInputDevice)
    }

    // The input is open from here, so claim the bring-up window before the first
    // suspension — see `bringingUpCapture`. `defer` clears it on every exit,
    // including the abort throw below.
    bringingUpCapture = true
    defer { bringingUpCapture = false }

    // `record()` returning true only means the session started running — not
    // that the input route is delivering frames. A Bluetooth mic spends up to a
    // couple of seconds switching into its mic-capable profile first, and the OS
    // captures nothing in that window, so returning here immediately cues the
    // user to speak into a dead mic and the first words never reach the
    // transcript. Hold — `DictationSession` keeps the pill in `.connecting` and
    // the start chime waits — until the recorder is clocking *and* metering real
    // samples, capped per transport and FAILING CLOSED on timeout (the throw
    // below). `MicLiveness` owns both policies and the reasoning, including why
    // the clock alone was not enough.
    let timeout = MicLiveness.timeout(forTransportType: resolved.input?.transportType)
    let generationBeforeWait = stopGeneration
    // Both probes read off-actor (`waitUntilLive` is nonisolated), safe by
    // confinement: the polls run sequentially in one task and nothing else
    // references this recorder while `start()` is suspended — it isn't
    // `activeRecorder` yet, the warm slot was cleared above, and the meter task
    // hasn't started. Meters read stale until refreshed, exactly as in `emitLevel`.
    let gap = await MicLiveness.waitUntilLive(
      timeout: timeout, clock: ContinuousClock(),
      currentTime: { recorder.currentTime },
      inputPowerDB: { recorder.meteredPowerDB() })

    // Two ways the bring-up can be abandoned while suspended, both ending the
    // same way — tear the recorder down instead of installing it, so nothing is
    // left capturing:
    //
    // - A teardown landed (`stopGeneration` moved), so the caller's stop has to
    //   stay a real stop rather than returning an empty "clean" one.
    // - The task was cancelled, which is how a cancel preempts the wait:
    //   `waitUntilLive` returns as soon as it sees it, so this is the difference
    //   between an Escape acting now and acting in `bluetoothTimeout`. It must be
    //   distinguished from the timeout, which returns nil too but is a reported
    //   *failure* (the throw below) — a cancel is the user's own act, not a fault.
    guard stopGeneration == generationBeforeWait, !Task.isCancelled else {
      recorder.stopAndDiscard()
      Self.logger.info("start aborted — teardown or cancellation during the liveness wait")
      throw CancellationError()
    }

    // The gate's outcome, worded in `MicLiveness` so the line a field report is
    // read off is unit-tested. See `logSummary` for what it has to carry.
    let summary = MicLiveness.logSummary(
      gap: gap, timeout: timeout, transportType: resolved.input?.transportType,
      powerDB: recorder.meteredPowerDB())
    Self.logger.log(level: gap == nil ? .error : .info, "\(summary, privacy: .public)")
    // No confirmed signal within the cap: fail CLOSED — tear the capture down and
    // surface the same `.audioCaptureFailed` presentation as the record()-false
    // path above (the error pill), instead of claiming `.recording` and chiming
    // "speak now" over a mic delivering nothing; a recording made anyway would
    // discard the user's words after the fact. The recorder was never installed,
    // so no stopGeneration bump — a concurrent stop() correctly sees no active
    // capture — and `bringingUpCapture` is cleared by the defer above.
    guard gap != nil else {
      recorder.stopAndDiscard()
      throw BlurtError.audioCaptureFailed(underlying: MicCaptureError.inputNeverDelivered)
    }

    activeRecorder = recorder
    activeTransportType = resolved.input?.transportType
    lastEmittedLevel = nil
    Self.logger.info("start recording to \(recorder.logName, privacy: .public)")
    startMeterTimer()
  }

  public func stop() async throws -> Data {
    // Read before the suspension below, so this capture's decision can't be
    // rewritten by whatever a later `start()` sets.
    let linger = AudioTransport.tailLinger(forTransportType: activeTransportType)
    guard let recorder = detachActiveRecorder() else { return Data() }
    if linger > .zero {
      // Keep capturing for a moment past key-up so the audio still travelling
      // over the link lands in the recording instead of being truncated. See
      // `AudioTransport.tailLinger(forTransportType:)`.
      try? await Task.sleep(for: linger)
    }
    defer {
      // Re-arm for the *next* press now that the device is free, so the route
      // activation this session just paid for isn't paid again. Scheduled rather
      // than done inline: preparing re-opens the input, which is the slow part,
      // and `stop()` is on the release path the transcript waits behind.
      scheduleRewarm()
    }
    let pcm = try recorder.stopAndReadPCM()

    let sampleCount = pcm.count / SyncSTTLimits.bytesPerSample
    let durationMs = SyncSTTLimits.durationMs(ofPCMBytes: pcm.count)
    let lingerMs = Int(linger.milliseconds.rounded())
    Self.logger.info("stop samples=\(sampleCount) durationMs=\(durationMs) lingerMs=\(lingerMs)")
    return pcm
  }

  /// Ends the capture and throws the audio away — the teardown behind
  /// `DictationSession`'s cancels.
  ///
  /// Deliberately *not* `stop()`-and-discard: the user asked for nothing to
  /// happen, so `stop()`'s one cost isn't worth paying. The Bluetooth tail
  /// linger would delay the `.cancelled` phase (and with it the pill's
  /// dismissal) to preserve audio about to be deleted.
  ///
  /// Not marked `throws`, because nothing on this path can fail — a
  /// non-throwing implementation satisfies the `throws` requirement fine. The
  /// *requirement* keeps it, so that the protocol's stop-and-discard default
  /// (which can throw, via `stop()`) still conforms and `stopAndCancel`'s
  /// developer-mode failure log keeps working for hosts that take it.
  public func cancelCapture() {
    guard let recorder = detachActiveRecorder() else { return }
    recorder.stopAndDiscard()
    Self.logger.info("cancelled capture, discarded audio")
    scheduleRewarm()
  }

  /// Ends the current capture's claim on the actor's state and hands back the
  /// recorder to dispose of, or nil when there was none.
  ///
  /// Shared by `stop()` and `cancelCapture()` because the two must not diverge:
  /// the generation bump in particular is what `start()` re-checks across its
  /// liveness wait to know a teardown landed, so a third exit that forgot it
  /// would let an abandoned bring-up install itself and keep capturing.
  private func detachActiveRecorder() -> (any CaptureRecorder)? {
    stopGeneration += 1
    meterTask?.cancel()
    meterTask = nil
    defer { activeRecorder = nil }
    return activeRecorder
  }

  // MARK: - Input resolution

  /// The input a capture (or warm-up) resolved to bind to: the snapshot the
  /// transport policies key off — of the *pinned* device when one is pinned and
  /// present, so the liveness cap, tail linger and warm-recorder identity check
  /// all follow the device actually recorded — plus the UID the recorder must
  /// pin to, nil when it records the system default (no pin, or the fallback).
  struct ResolvedInput {
    let input: AudioRoute.InputSnapshot?
    let pinnedUID: String?
  }

  /// One trip through the selection policy: resolve the pinned UID to a live
  /// device (or notice it's gone), let `MicDeviceSelection.effective` — the
  /// pure, unit-tested rule — pick the fallback, and read the snapshot of
  /// whichever input won. Hardware-adjacent glue in a coverage-excluded file;
  /// the decision itself stays testable.
  static func resolveInput(selection: MicDeviceSelection) -> ResolvedInput {
    var pinnedInput: AudioRoute.InputSnapshot?
    if case .pinned(let uid) = selection {
      pinnedInput = AudioInputDevices.input(forUID: uid)
    }
    switch selection.effective(pinnedDevicePresent: pinnedInput != nil) {
    case .pinned(let uid):
      return ResolvedInput(input: pinnedInput, pinnedUID: uid)
    case .systemDefault:
      if case .pinned = selection {
        // Graceful degradation, not an error: the pin stays stored, and this
        // capture records what an un-pinned one would.
        logger.info("pinned microphone not connected — recording the system default input")
      }
      return ResolvedInput(input: AudioRoute.currentInput(), pinnedUID: nil)
    }
  }

  // MARK: - Level metering

  private func startMeterTimer() {
    meterTask = Task { [weak self] in
      while !Task.isCancelled {
        // Rebound per iteration so the actor stays releasable across the sleep.
        // Bail when it's gone: deinit doesn't cancel this task, so the weak
        // capture is what stops an orphaned meter from spinning at ~20 Hz for
        // the rest of the process if a capture is dropped without stop().
        guard let self else { return }
        await self.emitLevel()
        try? await Task.sleep(for: Self.meterInterval)
      }
    }
  }

  private func emitLevel() {
    guard let recorder = activeRecorder else { return }
    let level = Self.linearLevel(fromPowerDB: recorder.meteredPowerDB())
    // Only yield transitions. `linearLevel` floors room ambient to exactly 0, so a
    // silent stretch would otherwise push the same value 20×/s, resuming the
    // host's `@MainActor` observer each time just to have it discard the
    // duplicate. Hosts still guard their own side (the range contract is the
    // seam's), but the cheapest place to drop a no-op tick is before it crosses.
    guard level != lastEmittedLevel else { return }
    lastEmittedLevel = level
    levelsContinuation.yield(level)
  }

  // The dB→0...1 conversion `emitLevel` uses lives in `MicCapture+Meter.swift`
  // — pure math the coverage gate counts, unlike this hardware-bound actor. The
  // warm-recorder lifecycle lives in `MicCapture+Warm.swift`, and the recorder
  // seam with its factory in `CaptureRecorder.swift` — both split off for the
  // lint file-length budget, which is why the warm state, `logger`,
  // `deviceSelection` and `makeBackend` are internal rather than private.
}
