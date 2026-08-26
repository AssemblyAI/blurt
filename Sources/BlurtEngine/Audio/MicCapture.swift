import Foundation
import os

/// Captures mic audio as the 16 kHz / mono / 16-bit PCM the dictation API wants
/// — so there's no manual tap, resample pass, or PCM plumbing here. Each
/// session uses a freshly built `CaptureSessionRecorder`: an `AVCaptureSession`
/// around the *current* resolution of the user's selection — the device pinned
/// in Settings (`MicDeviceSelection`), or the system default input. The fresh
/// recorder per session is the whole reason this is not a long-lived engine
/// graph: that graph bound its input to one device and went stale on a device
/// switch, raising `-10868` or quietly capturing all-zero buffers; per-session
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

  /// The recorder for the in-flight session; nil between `stop()` and `start()`.
  private var activeRecorder: CaptureSessionRecorder?
  /// How long `stop()` keeps capturing past key-up for the in-flight session —
  /// `.zero` off Bluetooth. Decided at `start()` from the resolved transport
  /// rather than re-read at stop, so a device switch mid-utterance can't make
  /// the two halves of one capture disagree; stored as the `Duration` itself
  /// because the transport has no other reader once the cap is chosen.
  private var activeTailLinger: Duration = .zero

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

  /// Absorbs the one-off cost of this process's first touch of AVFoundation's
  /// capture stack, by building a session for the current selection and dropping
  /// it. Holds no state: there is no warm recorder, nothing to validate against
  /// the live route at press time, and nothing to tear down.
  ///
  /// That is deliberate, and it is a measurement rather than a preference. This
  /// actor used to keep a prepared recorder between presses — re-warmed after
  /// every capture, validated against the resolved input's device identity and
  /// pin, and guarded by a bring-up flag so a re-warm couldn't race a live
  /// press. What that machinery bought, timed against
  /// `kAudioDevicePropertyDeviceIsRunningSomewhere` on real hardware, was ~15 ms
  /// of a ~600 ms bring-up: neither building an `AVCaptureSession` **nor** the
  /// retired `AVAudioRecorder.prepareToRecord()` opens the device (the indicator
  /// bit stays clear through both), so neither could pre-pay the route
  /// activation the warm recorder existed to hide. `record()`'s `startRunning()`
  /// pays all of it, inside the connecting window the liveness gate already
  /// covers. Only the first build in a process is worth pre-paying — ~185 ms of
  /// framework set-up (~90–125 ms of it the first device query, the rest the
  /// session and its input), against ~5 ms for every build after it — and that
  /// needs no state to hold.
  ///
  /// Reads the pin straight off the selection rather than running `start()`'s
  /// input resolution: what is being pre-paid is process-level framework set-up,
  /// which is the same whichever device is named, and resolving here would spend
  /// two device lookups on a value the recorder resolves again anyway — and
  /// would log `resolveInput`'s "pinned microphone not connected" line at launch,
  /// where nothing is being recorded. Naming the pin still costs a microsecond,
  /// so it stays: if a driver has its own first-load cost, this pre-pays it.
  ///
  /// Never throws (a failure just leaves `start()` to build the real one) and
  /// never begins capture, so no input indicator appears.
  public func warmUp() async {
    do {
      _ = try await CaptureSessionRecorder.make(pinnedUID: deviceSelection().pinnedUID)
      Self.logger.info("warmed the capture stack")
    } catch {
      Self.logger.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func start() async throws {
    // The selection, resolved once per press: which device to pin the session to
    // (or nil to follow the system default, including the missing-pin fallback),
    // and the transport the liveness cap and the tail linger key off.
    let resolved = Self.resolveInput(selection: deviceSelection())

    // Snapshotted before the first suspension, which is the *build* — both it
    // and the open hop off-actor (see `CaptureSessionRecorder.make`), so a stop
    // or cancel can land anywhere in the bring-up, and it has to win over a
    // bring-up that is no longer wanted.
    let generationBeforeBringUp = stopGeneration
    let recorder = try await CaptureSessionRecorder.make(pinnedUID: resolved.pinnedUID)

    // One teardown for every exit that doesn't install the recorder — a failed
    // open, either abandonment check, the fail-closed timeout. Written once as a
    // `defer` rather than at each `throw`, because forgetting it at any of them
    // leaves a session capturing with nothing holding it: a hot input indicator
    // and no owner, which is the failure `stopGeneration` exists to prevent. A
    // future suspension point in this bring-up inherits the teardown for free
    // and only has to add its own abandonment check.
    var installed = false
    defer { if !installed { recorder.stopAndDiscard() } }

    // record() answers false when no usable input device is available (unplugged,
    // asleep, route lost). Surface that as a thrown Swift error so
    // DictationSession.press() reports `.audioCaptureFailed` instead of recording
    // nothing. (No path here can raise an uncatchable Obj-C exception, so there's
    // no degenerate-format guard to keep.)
    guard await recorder.record() else {
      Self.logger.error("recorder.record() returned false — no usable input device")
      throw BlurtError.audioCaptureFailed(underlying: MicCaptureError.noInputDevice)
    }

    // A teardown or cancel that landed during the open: tear the recorder down
    // instead of sitting through the liveness wait for a capture nobody wants.
    // Same handling as the post-wait check below, just earlier — see it for why
    // the two conditions are distinguished from a timeout.
    guard stopGeneration == generationBeforeBringUp, !Task.isCancelled else {
      Self.logger.info("start aborted — teardown or cancellation during the device open")
      throw CancellationError()
    }

    // `record()` returning true only means the session started running — not
    // that the input route is delivering frames. A Bluetooth mic spends up to a
    // couple of seconds switching into its mic-capable profile first, and the OS
    // captures nothing in that window, so returning here immediately cues the
    // user to speak into a dead mic and the first words never reach the
    // transcript. Hold — `DictationSession` keeps the pill in `.connecting` and
    // the start chime waits — until the recorder is delivering frames *and*
    // metering real samples, capped per transport and FAILING CLOSED on timeout
    // (the throw below). `MicLiveness` owns both policies and the reasoning,
    // including why frame arrival alone was not enough.
    let timeout = MicLiveness.timeout(forTransportType: resolved.transportType)
    // Both probes read off-actor (`waitUntilLive` is nonisolated), safe by
    // confinement: the polls run sequentially in one task and nothing else
    // references this recorder while `start()` is suspended — it isn't
    // `activeRecorder` yet, and the meter task hasn't started. Meters read stale
    // until refreshed, exactly as in `emitLevel`.
    let gap = await MicLiveness.waitUntilLive(
      timeout: timeout, clock: ContinuousClock(),
      deliveredFrames: { recorder.deliveredFrames },
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
    guard stopGeneration == generationBeforeBringUp, !Task.isCancelled else {
      Self.logger.info("start aborted — teardown or cancellation during the liveness wait")
      throw CancellationError()
    }

    // The gate's outcome, worded in `MicLiveness` so the line a field report is
    // read off is unit-tested. See `logSummary` for what it has to carry.
    let summary = MicLiveness.logSummary(
      gap: gap, timeout: timeout, transportType: resolved.transportType,
      powerDB: recorder.meteredPowerDB())
    Self.logger.log(level: gap == nil ? .error : .info, "\(summary, privacy: .public)")
    // No confirmed signal within the cap: fail CLOSED — tear the capture down and
    // surface the same `.audioCaptureFailed` presentation as the record()-false
    // path above (the error pill), instead of claiming `.recording` and chiming
    // "speak now" over a mic delivering nothing; a recording made anyway would
    // discard the user's words after the fact. The recorder was never installed,
    // so no stopGeneration bump — a concurrent stop() correctly sees no active
    // capture.
    guard gap != nil else {
      throw BlurtError.audioCaptureFailed(underlying: MicCaptureError.inputNeverDelivered)
    }

    activeRecorder = recorder
    activeTailLinger = AudioTransport.tailLinger(forTransportType: resolved.transportType)
    lastEmittedLevel = nil
    installed = true
    Self.logger.info(
      "start recording from \(resolved.pinnedUID ?? "system default", privacy: .public)")
    startMeterTimer()
  }

  public func stop() async throws -> Data {
    let linger = activeTailLinger
    guard let recorder = detachActiveRecorder() else { return Data() }
    if linger > .zero {
      // Keep capturing for a moment past key-up so the audio still travelling
      // over the link lands in the recording instead of being truncated. See
      // `AudioTransport.tailLinger(forTransportType:)`.
      try? await Task.sleep(for: linger)
    }
    let pcm = recorder.stopAndReadPCM()

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
  }

  /// Ends the current capture's claim on the actor's state and hands back the
  /// recorder to dispose of, or nil when there was none.
  ///
  /// Shared by `stop()` and `cancelCapture()` because the two must not diverge:
  /// the generation bump in particular is what `start()` re-checks across its
  /// liveness wait to know a teardown landed, so a third exit that forgot it
  /// would let an abandoned bring-up install itself and keep capturing.
  private func detachActiveRecorder() -> CaptureSessionRecorder? {
    stopGeneration += 1
    meterTask?.cancel()
    meterTask = nil
    defer {
      activeRecorder = nil
      activeTailLinger = .zero
    }
    return activeRecorder
  }

  // MARK: - Input resolution

  /// What a press needs to know about its input, and nothing more: the UID the
  /// session must pin to (nil for the system default — no pin, or the
  /// missing-device fallback), and the transport the two transport-keyed
  /// policies read (`MicLiveness.timeout`, `AudioTransport.tailLinger`).
  ///
  /// It used to carry the resolved device's `AudioDeviceID` as well, purely so a
  /// warm recorder could be checked for still being bound to it. With no warm
  /// recorder to validate, nothing asks which device this is — only how to open
  /// it and how its link behaves.
  struct ResolvedInput {
    let pinnedUID: String?
    let transportType: UInt32?
  }

  /// One trip through the selection policy: check whether the pinned UID still
  /// names a connected device, let `MicDeviceSelection.effective` — the pure,
  /// unit-tested rule — pick the fallback, and read the transport of whichever
  /// input won. Hardware-adjacent glue in a coverage-excluded file; the decision
  /// itself stays testable.
  static func resolveInput(selection: MicDeviceSelection) -> ResolvedInput {
    // One device lookup, answering both questions: the transport is nil exactly
    // when no connected device carries the pin (see
    // `AudioInputDevices.transportType(forUID:)`), so presence is `!= nil` and
    // the value is reused below instead of read a second time.
    let pinnedTransport = selection.pinnedUID.flatMap(AudioInputDevices.transportType(forUID:))
    switch selection.effective(pinnedDevicePresent: pinnedTransport != nil) {
    case .pinned(let uid):
      return ResolvedInput(pinnedUID: uid, transportType: pinnedTransport)
    case .systemDefault:
      if case .pinned = selection {
        // Graceful degradation, not an error: the pin stays stored, and this
        // capture records what an un-pinned one would.
        logger.info("pinned microphone not connected — recording the system default input")
      }
      return ResolvedInput(
        pinnedUID: nil, transportType: AudioInputDevices.systemDefaultTransportType())
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
  // — pure math the coverage gate counts, unlike this hardware-bound actor,
  // which is why `logger` and `deviceSelection` are internal rather than
  // private.
}
