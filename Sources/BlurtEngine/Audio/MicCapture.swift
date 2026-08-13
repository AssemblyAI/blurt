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
  private static let logger = Logger(subsystem: BlurtIdentity.subsystem, category: "MicCapture")

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
  private var preparedRecorder: AVAudioRecorder?
  /// The default input `preparedRecorder` was built against. `AVAudioRecorder`
  /// resolves its device once, at `prepareToRecord()`, and never re-resolves —
  /// so without this a recorder warmed while the built-in mic was default would
  /// keep recording from it after the user connected their AirPods. See
  /// `AudioRoute.InputSnapshot.deviceID` for why identity is the device ID.
  private var preparedInput: AudioRoute.InputSnapshot?
  /// Releases `preparedRecorder` once it has gone unused for
  /// `preparedRecorderLifetime`. See that constant for why holding one open
  /// forever is not an option.
  private var preparedExpiry: Task<Void, Never>?

  /// The recorder for the in-flight session; nil between `stop()` and `start()`.
  private var activeRecorder: AVAudioRecorder?
  /// Whether the in-flight session's input is a Bluetooth device, sampled once
  /// at `start()`. Read by `stop()` to decide on the tail linger — sampled at
  /// start rather than re-read at stop so a device switch mid-utterance can't
  /// make the two halves of one capture disagree.
  private var activeInputIsBluetooth = false

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

  /// How much longer capture runs after the key-up that ends it, when the input
  /// is a Bluetooth device.
  ///
  /// A Bluetooth link buffers: audio the user has already spoken is still in
  /// flight when `stop()` is called, and `recorder.stop()` drops it — which is
  /// why the last word of a dictation goes missing on AirPods and the app reads
  /// as running behind the speaker. The linger is deliberately shorter than a
  /// typical link's worst case: it buys back the common tail without making
  /// every dictation feel sluggish, and it costs nothing on a wired input, where
  /// it is skipped entirely.
  ///
  /// The delay lands *after* `.transcribing` is claimed (see
  /// `DictationSession.performRelease`), so it delays the transcript, never the
  /// user's "it heard me" cue. Cancels skip it — see `cancelCapture()`.
  static let bluetoothTailLinger = Duration.milliseconds(220)

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
  private static let preparedRecorderLifetime = Duration.seconds(60)

  public init() {
    // The continuation is fed from a ~20 Hz meter timer; the levels stream is a
    // meter, not the captured signal — the consumer only renders the most recent
    // value — so cap it at the newest single element.
    let (stream, continuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
    self.levels = stream
    self.levelsContinuation = continuation
  }

  /// Pre-create and prepare a recorder so the first `start()` skips first-time
  /// hardware route discovery. Does NOT begin capture — no mic indicator. Safe to
  /// call multiple times; a failure here just leaves `start()` to prepare lazily.
  public func warmUp() {
    guard preparedRecorder == nil, activeRecorder == nil else { return }
    prepareWarmRecorder()
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

    activeRecorder = recorder
    activeInputIsBluetooth = input?.isBluetooth ?? false
    lastEmittedLevel = nil
    Self.logger.info("start recording to \(recorder.url.lastPathComponent, privacy: .public)")
    startMeterTimer()
  }

  public func stop() async throws -> Data {
    meterTask?.cancel()
    meterTask = nil
    guard let recorder = activeRecorder else { return Data() }
    activeRecorder = nil
    // Read before the suspension below, so this capture's decision can't be
    // rewritten by whatever a later `start()` sets.
    let lingerForTail = activeInputIsBluetooth
    if lingerForTail {
      // Keep capturing for a moment past key-up so the audio still travelling
      // over the link lands in the file instead of being truncated. See
      // `bluetoothTailLinger`.
      try? await Task.sleep(for: Self.bluetoothTailLinger)
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
    Self.logger.info("stop samples=\(sampleCount) durationMs=\(durationMs) linger=\(lingerForTail)")
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
    meterTask?.cancel()
    meterTask = nil
    guard let recorder = activeRecorder else { return }
    activeRecorder = nil
    recorder.stop()
    Self.removeFile(at: recorder.url)
    Self.logger.info("cancelled capture, discarded audio")
    scheduleRewarm()
  }

  // MARK: - Warm recorder

  /// The warm recorder if it is still bound to `input`, else nil — discarding
  /// (and cleaning up after) one that isn't.
  ///
  /// Reuse requires *positively* confirming the device is unchanged: an
  /// unreadable route on either side leaves us unable to tell, and a recorder
  /// bound to the wrong device doesn't fail loudly — it records the wrong mic, or
  /// silence. Paying route activation is the cheaper mistake, so unknown means
  /// discard.
  private func takeWarmRecorder(matching input: AudioRoute.InputSnapshot?) -> AVAudioRecorder? {
    preparedExpiry?.cancel()
    preparedExpiry = nil
    guard let recorder = preparedRecorder else { return nil }
    let warmed = preparedInput
    preparedRecorder = nil
    preparedInput = nil
    guard let warmed, let input, warmed.deviceID == input.deviceID else {
      Self.removeFile(at: recorder.url)
      Self.logger.info("discarded warm recorder — input device changed since warm-up")
      return nil
    }
    return recorder
  }

  /// Queues a re-warm to run once the current actor turn finishes, so the caller
  /// (`stop()` / `cancelCapture()`) returns before the input is re-opened.
  private func scheduleRewarm() {
    Task { [weak self] in
      await self?.rewarm()
    }
  }

  /// Prepares the next session's recorder, unless a capture has already started
  /// or a warm one is already held — both of which mean this re-warm has been
  /// overtaken and has nothing to do.
  private func rewarm() {
    guard activeRecorder == nil, preparedRecorder == nil else { return }
    prepareWarmRecorder()
  }

  /// Builds a recorder, records the input it is bound to, and starts its idle
  /// countdown. A failure is non-fatal: `start()` then prepares lazily, exactly
  /// as it did before any warm recorder existed.
  private func prepareWarmRecorder() {
    do {
      let recorder = try Self.makeRecorder()
      preparedRecorder = recorder
      preparedInput = AudioRoute.currentInput()
      armPreparedRecorderExpiry()
      Self.logger.info("prepared a warm recorder")
    } catch {
      Self.logger.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func armPreparedRecorderExpiry() {
    preparedExpiry?.cancel()
    preparedExpiry = Task { [weak self] in
      try? await Task.sleep(for: Self.preparedRecorderLifetime)
      guard !Task.isCancelled else { return }
      await self?.releasePreparedRecorder()
    }
  }

  /// Tears down an idle warm recorder, freeing the input device — which is what
  /// lets a Bluetooth output route return to its full-quality profile. See
  /// `preparedRecorderLifetime`.
  private func releasePreparedRecorder() {
    preparedExpiry = nil
    guard let recorder = preparedRecorder else { return }
    preparedRecorder = nil
    preparedInput = nil
    Self.removeFile(at: recorder.url)
    Self.logger.info("released idle warm recorder")
  }

  // MARK: - Recorder construction

  /// Build a recorder that writes mono 16-bit little-endian PCM at the target
  /// rate into a unique temp file. `prepareToRecord()` does the heavy route/buffer
  /// setup so the subsequent `record()` starts promptly.
  private static func makeRecorder() throws -> AVAudioRecorder {
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
  // — pure math the coverage gate counts, unlike this hardware-bound actor.

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

  private static func removeFile(at url: URL) {
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
