@preconcurrency import AVFoundation
import Foundation
import os

/// Captures mic audio with `AVAudioRecorder`, which records straight to the
/// 16 kHz / mono / 16-bit PCM the Sync STT API wants — so there's no manual tap,
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
  private static let logger = Logger(subsystem: "dev.alex.blurt", category: "MicCapture")

  public nonisolated let levels: AsyncStream<Float>
  private nonisolated let levelsContinuation: AsyncStream<Float>.Continuation

  /// The geometry the recorder converts hardware audio to on the fly. Matches the
  /// `sampleRate: 16_000` the pipeline hands the transcriber, so `stop()` returns
  /// samples ready to encode with no resampling pass.
  private static let targetSampleRate = 16_000.0

  /// Pre-prepared in `warmUp()` so the *first* dictation doesn't pay hardware
  /// route discovery on the hot path; consumed by the first `start()`. Every
  /// later session creates a fresh recorder instead, so a device switch is always
  /// reflected. (A switch in the brief launch→first-dictation window is not worth
  /// guarding against — it would cost a CoreAudio device listener for a case that
  /// effectively never happens.)
  private var preparedRecorder: AVAudioRecorder?
  /// The recorder for the in-flight session; nil between `stop()` and `start()`.
  private var activeRecorder: AVAudioRecorder?
  /// Polls the active recorder's meter and feeds `levels` while recording.
  private var meterTask: Task<Void, Never>?
  /// How often the meter is sampled for the overlay. ~30 Hz is visually smooth
  /// and far cheaper than the per-buffer tap it replaces.
  private static let meterInterval = Duration.milliseconds(33)

  public init() {
    // The continuation is fed from a ~30 Hz meter timer; the levels stream is a
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
    guard preparedRecorder == nil else { return }
    do {
      preparedRecorder = try Self.makeRecorder()
      Self.logger.info("warmUp prepared recorder")
    } catch {
      Self.logger.error("warmUp failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func start() async throws {
    // Reuse the warm recorder for the first session; otherwise build a fresh one
    // bound to the current default input device.
    let recorder: AVAudioRecorder
    if let prepared = preparedRecorder {
      recorder = prepared
      preparedRecorder = nil
    } else {
      recorder = try Self.makeRecorder()
    }

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
    Self.logger.info("start recording to \(recorder.url.lastPathComponent, privacy: .public)")
    startMeterTimer()
  }

  public func stop() async throws -> [Float] {
    meterTask?.cancel()
    meterTask = nil
    guard let recorder = activeRecorder else { return [] }
    activeRecorder = nil
    recorder.stop()

    let url = recorder.url
    defer { Self.removeFile(at: url) }
    let samples = try Self.decodeSamples(fromFileAt: url)

    let durationMs = Int((Double(samples.count) / Self.targetSampleRate) * 1000)
    Self.logger.info("stop samples=\(samples.count) durationMs=\(durationMs)")
    return samples
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
        await self?.emitLevel()
        try? await Task.sleep(for: Self.meterInterval)
      }
    }
  }

  private func emitLevel() {
    guard let recorder = activeRecorder else { return }
    recorder.updateMeters()
    levelsContinuation.yield(Self.linearLevel(fromPowerDB: recorder.averagePower(forChannel: 0)))
  }

  /// Lowest dBFS meter reading treated as audible; anything quieter (room
  /// ambient) maps to 0. Deliberately set above typical built-in-mic noise: the
  /// overlay's auto-gain stretches *any* steady nonzero level back to a full bar,
  /// so silence must floor to exactly 0 or the meter reads full at rest.
  static let meterFloorDB: Float = -50

  /// Convert `AVAudioRecorder`'s dBFS meter power into the `0...1` the overlay
  /// expects, mapped linearly across `[meterFloorDB, 0]`. (A raw `pow(10, db/20)`
  /// amplitude leaves ambient noise well above zero, which the auto-gain then
  /// inflates into a full bar at rest — the meter looked inverted.)
  static func linearLevel(fromPowerDB db: Float) -> Float {
    guard db.isFinite, db > meterFloorDB else { return 0 }
    return min(1, (db - meterFloorDB) / -meterFloorDB)
  }

  // MARK: - File helpers

  /// Read a recorded PCM file back as mono Float32 at its stored sample rate.
  /// `AVAudioFile.processingFormat` is always Float32, so this also performs the
  /// on-disk int16 → float conversion the Sync encoder expects.
  static func decodeSamples(fromFileAt url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
    else { return [] }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
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
