@preconcurrency import AVFoundation
import Foundation

/// The one-session recording surface `MicCapture` drives, abstracted over which
/// backend records: an un-pinned capture — the shipping default — keeps the
/// `AVAudioRecorder` WAV path exactly as it was (`WAVFileRecorder`), and a
/// capture pinned to a specific device takes `PinnedAudioQueueRecorder`, the
/// macOS capture surface that accepts a per-instance device. Both are built
/// fresh per session — the invariant the capture design rests on — and both
/// feed the same liveness gate, meter, warm-recorder and tail-linger machinery
/// through this seam, so pinning changes which device is opened and nothing
/// else.
///
/// `Sendable` because `MicCapture.start()`'s liveness probes read the recorder
/// off-actor; conformers are `@unchecked Sendable` on the same confinement
/// argument the raw recorder relied on there — the polls run sequentially in
/// one task while `start()` is suspended and nothing else references the
/// recorder in that window (the AudioQueue backend additionally locks the state
/// its CoreAudio callback thread shares).
protocol CaptureRecorder: AnyObject, Sendable {
  /// Begin capturing. False when no usable input device is available.
  func record() -> Bool
  /// Seconds the recorder's clock has advanced since `record()` — 0 until the
  /// underlying queue is started and clocking. Consulted only as the liveness
  /// gate's has-the-clock-moved probe; frames of digital silence advance it
  /// exactly like real audio (see `MicLiveness.waitUntilLive`).
  var currentTime: TimeInterval { get }
  /// Refresh and read the input's average power in dBFS. Feeds both the
  /// liveness gate's silence-floor probe and the overlay meter.
  func meteredPowerDB() -> Float
  /// End capture and return everything recorded as raw S16LE PCM at the
  /// dictation API's rate, releasing the device and any temp storage.
  func stopAndReadPCM() throws -> Data
  /// End capture and throw the audio away, releasing the device and any temp
  /// storage — the teardown behind a failed `record()`, an aborted bring-up, a
  /// discarded warm recorder, and a cancel.
  func stopAndDiscard()
  /// A short name for the capture-start log line (the WAV path's temp filename;
  /// a fixed tag for the pinned queue).
  var logName: String { get }
}

/// The system-default backend: `AVAudioRecorder` recording straight to a temp
/// 16 kHz / mono / 16-bit WAV, read back as raw S16LE bytes on stop. This is
/// the shipped capture path, moved behind the seam verbatim — every capture
/// that isn't pinned to a device still goes through exactly this.
final class WAVFileRecorder: CaptureRecorder, @unchecked Sendable {
  private let recorder: AVAudioRecorder

  init() throws {
    recorder = try MicCapture.makeRecorder()
  }

  func record() -> Bool { recorder.record() }

  var currentTime: TimeInterval { recorder.currentTime }

  func meteredPowerDB() -> Float {
    recorder.updateMeters()
    return recorder.averagePower(forChannel: 0)
  }

  func stopAndReadPCM() throws -> Data {
    recorder.stop()
    defer { MicCapture.removeFile(at: recorder.url) }
    return try MicCapture.decodePCM(fromFileAt: recorder.url)
  }

  func stopAndDiscard() {
    recorder.stop()
    MicCapture.removeFile(at: recorder.url)
  }

  var logName: String { recorder.url.lastPathComponent }
}

// The construction and file plumbing behind `WAVFileRecorder`, plus the
// backend choice itself. Statics on `MicCapture` (moved here from
// `MicCapture.swift` for its lint file-length budget, like `+Meter` and
// `+Warm`): `decodePCM` keeps its home so `MicCaptureFormatTests` pins the
// decode against the same symbol the capture uses.
extension MicCapture {
  /// The backend for a resolved input: a pinned UID gets the AudioQueue
  /// recorder bound to that device; no pin gets the WAV recorder on the system
  /// default. The only place the two backends are told apart.
  static func makeBackend(pinnedUID: String?) throws -> any CaptureRecorder {
    guard let pinnedUID else { return try WAVFileRecorder() }
    return try PinnedAudioQueueRecorder(deviceUID: pinnedUID)
  }

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
