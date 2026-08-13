@preconcurrency import AVFoundation
import Foundation
import os

/// Captures mic audio with `AVAudioRecorder`, which records straight to the
/// 16 kHz / mono / 16-bit PCM the dictation API wants — so there's no manual tap,
/// sample-rate conversion, or PCM plumbing here. Each session uses a freshly
/// created recorder, which resolves the *current* default input device at
/// `record()` time. That's the whole reason this is no longer an `AVAudioEngine`:
/// the engine's input graph bound to one device and went stale on a device switch
/// (mic ↔ built-in), raising `-10868` (`kAudioUnitErr_FormatNotSupported`) or
/// quietly capturing all-zero buffers. A per-session recorder can't go stale.
public actor MicCapture: MicCaptureProtocol {
  // Subsystem/category make these lines findable via:
  //   log show --predicate 'subsystem == "dev.alex.blurt"' --last 1h
  // Stderr is unreachable for .app bundles launched via Finder/LaunchServices,
  // so go through the unified logging system instead.
  static let logger = Logger(subsystem: BlurtIdentity.subsystem, category: "MicCapture")

  public nonisolated let levels: AsyncStream<Float>
  private nonisolated let levelsContinuation: AsyncStream<Float>.Continuation

  /// The geometry the recorder converts hardware audio to on the fly. The dictation
  /// API's rate (`SyncSTTLimits.sampleRate`) — the same one the pipeline hands
  /// the transcriber — so `stop()` returns bytes ready to upload with no
  /// resampling or re-encoding pass.
  private static let targetSampleRate = Double(SyncSTTLimits.sampleRate)

  /// A recorder prepared ahead of the press so `start()` doesn't pay hardware
  /// route activation on the hot path. Filled by `warmUp()` at launch and
  /// **re-filled after every capture** (see `scheduleRewarm`), because that cost
  /// is paid per session, not once: `prepareToRecord()` is where the route is
  /// resolved and opened, and on a Bluetooth input that means renegotiating the
  /// link into its mic-capable mode — hundreds of milliseconds, sometimes over a
  /// second, during which the user has pressed the key and nothing has happened.
  /// Warming only the first session (the previous behavior) hid that cost for one
  /// dictation out of every N.
  ///
  /// Still a *fresh recorder per session*, which is the invariant the
  /// `AVAudioEngine` rewrite bought: the warm recorder is validated against the
  /// live default input before it is used (`takeWarmRecorder`) and discarded
  /// rather than reused when the device has changed underneath it.
  var preparedRecorder: AVAudioRecorder?
  /// The default input `preparedRecorder` was built against. `AVAudioRecorder`
  /// resolves its device once, at `prepareToRecord()`, and never re-resolves —
  /// so without this a recorder warmed while the built-in mic was default would
  /// keep recording from it after the user connected their AirPods. See
  /// `AudioRoute.InputSnapshot.deviceID` for why identity is the device ID.
  var preparedInput: AudioRoute.InputSnapshot?
  /// Releases `preparedRecorder` once it has gone unused for
  /// `preparedRecorderLifetime`. See that constant for why holding one open
  /// forever is not an option.
  var preparedExpiry: Task<Void, Never>?
  /// Bumped for each warm recorder prepared, and carried by that recorder's
  /// expiry task, so an expiry whose recorder has since been consumed or
  /// replaced can recognise itself as stale and do nothing. See
  /// `releasePreparedRecorder(generation:)` for why cancelling the task isn't
  /// sufficient on its own.
  var preparedGeneration = 0

  /// The recorder for the in-flight session; nil between `stop()` and `start()`.
  var activeRecorder: AVAudioRecorder?
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
  /// (mic indicator hot, temp WAV leaked) until `start()` resumed. Unreachable
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
  /// clock off-actor), and the warm slot was consumed on the way in. Without
  /// this, `warmUp()` (which every re-warm goes through) reads those two nils as
  /// "no capture in flight"
  /// and prepare a *second* recorder onto the already-live input — which is very
  /// reachable, since `stop()` schedules a re-warm that can land inside the next
  /// press's bring-up.
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

  /// How long a prepared-but-unused recorder is held before being torn down.
  ///
  /// The warm recorder is the fix for per-session route activation, but it is
  /// not free to hold: a prepared recorder keeps the input device open, and an
  /// open input is exactly what pins AirPods in their mic-capable profile, where
  /// *output* audio is degraded. Holding one indefinitely would trade dictation
  /// latency for permanently worse music. This bounds that: back-to-back
  /// dictations — the case the warm recorder exists for — land well inside the
  /// window, and a user who stops dictating gets their output route back shortly
  /// after. The next press past the window simply prepares lazily, which is the
  /// behavior that shipped before the re-warm existed.
  static let preparedRecorderLifetime = Duration.seconds(60)

  public init() {
    // The continuation is fed from a ~20 Hz meter timer; the levels stream is a
    // meter, not the captured signal — the consumer only renders the most recent
    // value — so cap it at the newest single element.
    let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.levels = stream
    self.levelsContinuation = continuation
  }

  public func start() async throws {
    // One CoreAudio read per session, answering both questions this capture has
    // about its input: whether the warm recorder is still bound to it, and
    // whether its link buffers a tail worth waiting for at stop.
    let input = AudioRoute.currentInput()
    // Reuse the warm recorder when it is still bound to the current default
    // input; otherwise build a fresh one. `??` only evaluates `makeRecorder()`
    // when nothing usable was warmed.
    let recorder = try takeWarmRecorder(matching: input) ?? Self.makeRecorder()

    // record() returns false when no usable input device is available (unplugged,
    // asleep, route lost). Surface that as a thrown Swift error so
    // DictationSession.press() reports `.audioCaptureFailed` instead of recording
    // nothing. (Unlike AVAudioEngine's installTap, no path here can raise an
    // uncatchable Obj-C exception, so there's no degenerate-format guard to keep.)
    guard recorder.record() else {
      Self.logger.error("recorder.record() returned false — no usable input device")
      Self.removeFile(at: recorder.url)
      throw BlurtError.audioCaptureFailed(underlying: MicCaptureError.noInputDevice)
    }

    // The input is open from here, so claim the bring-up window before the first
    // suspension — see `bringingUpCapture`. `defer` clears it on every exit,
    // including the abort throw below.
    bringingUpCapture = true
    defer { bringingUpCapture = false }

    // `record()` returning true only means the AudioQueue started — not that the
    // input route is delivering frames. A Bluetooth mic spends up to a couple of
    // seconds switching into its mic-capable profile first, and the OS captures
    // nothing in that window, so returning here immediately cues the user to
    // speak into a dead mic and the first words never reach the transcript.
    // Hold — `DictationSession` keeps the pill in `.connecting` and the start
    // chime waits — until the recorder's clock advances, capped per transport;
    // on timeout proceed anyway (fail open), which is exactly the old behavior.
    //
    // The re-warm above is what makes this cheap in the common case: a warm
    // recorder has already held the route open, so the wait usually returns
    // immediately. This gate is what makes it *correct* when it hasn't.
    let timeout = MicLiveness.timeout(forTransportType: input?.transportType)
    let generationBeforeWait = stopGeneration
    let gap = await MicLiveness.waitUntilLive(timeout: timeout, clock: ContinuousClock()) {
      // Off-actor read (`waitUntilLive` is nonisolated), safe by confinement:
      // the polls run sequentially within one task, and nothing else references
      // this recorder while `start()` is suspended in the wait — it isn't
      // `activeRecorder` yet, the warm slot was cleared above, and the meter
      // task hasn't started.
      recorder.currentTime
    }

    // Two ways the bring-up can be abandoned while suspended, both ending the
    // same way — tear the recorder down instead of installing it, so nothing is
    // left capturing and no temp file is orphaned:
    //
    // - A teardown landed (`stopGeneration` moved), so the caller's stop has to
    //   stay a real stop rather than returning an empty "clean" one.
    // - The task was cancelled, which is how a cancel preempts the wait:
    //   `waitUntilLive` returns as soon as it sees it, so this is the difference
    //   between an Escape acting now and acting in `bluetoothTimeout`. It must be
    //   distinguished from the timeout, which returns nil too but means "fail
    //   open, proceed as if live".
    guard stopGeneration == generationBeforeWait, !Task.isCancelled else {
      recorder.stop()
      Self.removeFile(at: recorder.url)
      Self.logger.info("start aborted — teardown or cancellation during the liveness wait")
      throw CancellationError()
    }

    if let gap {
      Self.logger.info("input live after \(Int(gap.milliseconds.rounded())) ms")
    } else {
      Self.logger.error(
        "input liveness unconfirmed after \(Int(timeout.milliseconds.rounded())) ms — proceeding")
    }

    activeRecorder = recorder
    activeTransportType = input?.transportType
    lastEmittedLevel = nil
    Self.logger.info("start recording to \(recorder.url.lastPathComponent, privacy: .public)")
    startMeterTimer()
  }

  public func stop() async throws -> Data {
    // Read before the suspension below, so this capture's decision can't be
    // rewritten by whatever a later `start()` sets.
    let linger = AudioTransport.tailLinger(forTransportType: activeTransportType)
    guard let recorder = detachActiveRecorder() else { return Data() }
    if linger > .zero {
      // Keep capturing for a moment past key-up so the audio still travelling
      // over the link lands in the file instead of being truncated. See
      // `AudioTransport.tailLinger(forTransportType:)`.
      try? await Task.sleep(for: linger)
    }
    recorder.stop()

    let url = recorder.url
    defer {
      Self.removeFile(at: url)
      // Re-arm for the *next* press now that the device is free, so the route
      // activation this session just paid for isn't paid again. Scheduled rather
      // than done inline: preparing re-opens the input, which is the slow part,
      // and `stop()` is on the release path the transcript waits behind.
      scheduleRewarm()
    }
    let pcm = try Self.decodePCM(fromFileAt: url)

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
  /// happen, so neither of `stop()`'s costs is worth paying. The Bluetooth tail
  /// linger would delay the `.cancelled` phase (and with it the pill's dismissal)
  /// to preserve audio about to be deleted, and reading the whole recording back
  /// off disk would decode a blob with no consumer.
  ///
  /// Not marked `throws`, because nothing on this path can fail — a
  /// non-throwing implementation satisfies the `throws` requirement fine. The
  /// *requirement* keeps it, so that the protocol's stop-and-discard default
  /// (which can throw, via `stop()`) still conforms and `stopAndCancel`'s
  /// developer-mode failure log keeps working for hosts that take it.
  public func cancelCapture() {
    guard let recorder = detachActiveRecorder() else { return }
    recorder.stop()
    Self.removeFile(at: recorder.url)
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
  private func detachActiveRecorder() -> AVAudioRecorder? {
    stopGeneration += 1
    meterTask?.cancel()
    meterTask = nil
    defer { activeRecorder = nil }
    return activeRecorder
  }

  // MARK: - Recorder construction

  /// Build a recorder that writes mono 16-bit little-endian PCM at the target
  /// rate into a unique temp file. `prepareToRecord()` does the heavy route/buffer
  /// setup so the subsequent `record()` starts promptly.
  static func makeRecorder() throws -> AVAudioRecorder {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("blurt-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: targetSampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()
    return recorder
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
    recorder.updateMeters()
    let level = Self.linearLevel(fromPowerDB: recorder.averagePower(forChannel: 0))
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
  // warm-recorder lifecycle (`warmUp`, `takeWarmRecorder`, the re-warm and its
  // expiry) lives in `MicCapture+Warm.swift`, split off for the lint
  // file-length budget — which is why the prepared-recorder state, `logger`,
  // `removeFile` and `makeRecorder` are internal rather than private.

  // MARK: - File helpers

  /// Read a recorded PCM file back as raw S16LE bytes — the dictation API's upload
  /// encoding. The on-disk WAV already holds 16-bit int samples, so asking
  /// `AVAudioFile` for the int16 common format makes this a straight copy-out:
  /// no detour through Float32 (which the default `processingFormat` would
  /// impose, and which the transcriber would only convert straight back). Int16
  /// is host-endian; Apple platforms (arm64/x86_64) are little-endian, so the
  /// bytes are already the S16LE the dictation API expects.
  static func decodePCM(fromFileAt url: URL) throws -> Data {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
    else { return Data() }
    try file.read(into: buffer)
    guard let channel = buffer.int16ChannelData?[0] else { return Data() }
    return Data(bytes: channel, count: Int(buffer.frameLength) * SyncSTTLimits.bytesPerSample)
  }

  static func removeFile(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}

enum MicCaptureError: LocalizedError {
  /// The active audio route reported no usable input device.
  case noInputDevice

  var errorDescription: String? {
    switch self {
    case .noInputDevice: "No microphone is available."
    }
  }
}
