@preconcurrency import AVFoundation
import CoreMedia
import Dispatch
import Foundation
import Synchronization

/// The capture backend (owner-directed move to `AVCaptureSession`, 2026-08-25):
/// a session built fresh per capture around a single audio device — the device
/// pinned in Settings when one is set, the system default otherwise — whose data
/// output converts to the dictation API's 16 kHz mono 16-bit LPCM on the fly and
/// delivers it here as sample buffers, accumulated in memory as the raw S16LE
/// blob `stopAndReadPCM` returns. No temp file, no resample pass, no decode on
/// the release path.
///
/// Used directly by `MicCapture` rather than through a protocol. There *was* a
/// `CaptureRecorder` seam, and its whole job was to let the actor's machinery —
/// liveness gate, meter, tail linger — be written once across two backends (an
/// `AVAudioRecorder` WAV path and a device-pinned `AudioQueue`). Both are gone,
/// so the seam abstracted a single conformer with no test double behind it; the
/// contract it documented now lives on these members. `MicCaptureProtocol` is
/// the seam hosts and tests actually inject at.
///
/// Fresh-per-session is load-bearing: the session's input is attached to one
/// device at build time and never re-resolves, so a session outliving a device
/// switch would record the wrong mic (or silence) rather than failing loudly.
/// `MicCapture` builds one per press and drops it at stop.
///
/// Building the session does **not** engage the microphone — measured against
/// CoreAudio's own `kAudioDevicePropertyDeviceIsRunningSomewhere`, the bit
/// behind the input indicator: it stays clear until `record()`. What building
/// costs is ~15 ms of object graph, and ~75 ms more the first time a process
/// touches AVFoundation's capture stack at all; the device open and route
/// activation — 180 ms on the built-in mic, ~600 ms on a USB interface, seconds
/// on a Bluetooth link — all land in `record()`'s `startRunning()`, inside the
/// press's connecting window. That measurement is why there is no warm-recorder
/// lifecycle here anymore (see `MicCapture.warmUp()`).
///
/// Hardware-bound like `MicCapture`, and excluded from the coverage gate for
/// the same reason; its live test rides the `BLURT_LIVE_AUDIO_TESTS` gate in
/// `AudioInputDevicesTests`.
///
/// `@unchecked Sendable`: `MicCapture.start()`'s liveness probes read
/// `deliveredFrames` and `meteredPowerDB()` off-actor, safe by confinement —
/// the polls run sequentially in one task while `start()` is suspended and
/// nothing else references the recorder in that window. The session/output
/// handles are configured in `init` and then only read, and everything the
/// delegate queue also touches lives behind the `Mutex`.
final class CaptureSessionRecorder: NSObject, @unchecked Sendable {
  private struct Guarded {
    /// Every byte the delegate has delivered, in arrival order — already the
    /// raw S16LE blob `stopAndReadPCM` returns.
    var captured = Data()
    /// Frames delivered so far, summed off each sample buffer's own count.
    /// Frames of digital silence count exactly like real audio; the liveness
    /// gate's power term is what tells those apart.
    var frameCount = 0
  }

  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  /// The serial queue sample buffers are delivered on; only the delegate
  /// method runs here, and it touches nothing but `state`.
  private let delegateQueue = DispatchQueue(
    label: HostIdentity.current.queueLabel("MicCaptureSession"))
  /// The serial queue `startRunning()` runs on — session *control*, deliberately
  /// not `delegateQueue`. Opening the device takes ~600 ms on a USB interface,
  /// and blocking the delivery queue for that long would stall the very frames
  /// the liveness gate is then waiting for. A dedicated `DispatchQueue` rather
  /// than a detached `Task`, so the wait parks a Dispatch thread instead of one
  /// of the cooperative pool's — the pool is what the rest of the press runs on
  /// (the context capture that overlaps this, the transcriber's connection
  /// warm-up), and starving it is how covering the retired backend in CI
  /// deadlocked the whole test run.
  private let sessionQueue = DispatchQueue(
    label: HostIdentity.current.queueLabel("MicCaptureSessionControl"))
  private let state = Mutex(Guarded())
  /// A short name for the capture-start log line.
  let logName: String

  /// Builds and fully configures the session — device input, converted-format
  /// data output, delegate — without starting it. Throws only when
  /// `AVCaptureDeviceInput` refuses the device (e.g. no microphone
  /// authorization); "no device at all" instead leaves the session inputless,
  /// so `record()` answers false and `MicCapture.start()` surfaces the same
  /// `.audioCaptureFailed(noInputDevice)` it always has.
  init(pinnedUID: String?) throws {
    logName = pinnedUID == nil ? "capture session (default input)" : "capture session (pinned input)"
    super.init()

    session.beginConfiguration()
    defer { session.commitConfiguration() }
    if let device = Self.device(forPinnedUID: pinnedUID) {
      let input = try AVCaptureDeviceInput(device: device)
      if session.canAddInput(input) {
        session.addInput(input)
      }
    }
    // The dictation API's geometry, converted by the output itself — the same
    // six keys the retired WAV recorder asked of its file, so capture still
    // lands in upload-ready S16LE with no resample pass anywhere.
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: Double(SyncSTTLimits.sampleRate),
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    output.setSampleBufferDelegate(self, queue: delegateQueue)
    if session.canAddOutput(output) {
      session.addOutput(output)
    }
  }

  deinit {
    // Backstop for a recorder dropped without a stop, so an orphaned instance
    // can't keep the microphone engaged for the rest of the process.
    if session.isRunning {
      session.stopRunning()
    }
  }

  /// The device the session records from: the pinned device when its UID still
  /// resolves (`AVCaptureDevice.uniqueID` is the CoreAudio device UID on
  /// macOS, the same string `MicDeviceStore` persists), else the default input
  /// — the same per-capture fallback `MicCapture.resolveInput` applies, kept
  /// here too so the race where the device vanishes between resolution and
  /// build degrades identically. Nil when the machine has no input at all.
  private static func device(forPinnedUID pinnedUID: String?) -> AVCaptureDevice? {
    if let pinnedUID, let pinned = AVCaptureDevice(uniqueID: pinnedUID) {
      return pinned
    }
    return AVCaptureDevice.default(for: .audio)
  }

  /// Opens the device and starts capture, answering false when there is no
  /// usable input: nothing was attached at build time, or the session refused to
  /// run.
  ///
  /// This is where the route-activation cost lives, all of it — ~180 ms on the
  /// built-in mic, ~600 ms on a USB interface, and on AirPods ~80 ms before
  /// `startRunning()` returns plus ~400 ms before the first frame. It is `async`
  /// and hops to `sessionQueue` precisely because that cost is unbounded from the
  /// caller's point of view: run inline it blocked `MicCapture` for the whole
  /// open, and a teardown arriving in that window measured 578 ms of waiting on a
  /// 635 ms open (`MicCaptureBringUpTests`). Suspending instead of blocking means
  /// the actor stays available to the stop and cancel that may be racing this.
  ///
  /// The suspension is why `MicCapture.start()` snapshots `stopGeneration`
  /// *before* calling this and re-checks after: a teardown can now land during
  /// the open, and it has to win.
  func record() async -> Bool {
    guard !session.inputs.isEmpty else { return false }
    return await withCheckedContinuation { continuation in
      sessionQueue.async {
        self.session.startRunning()
        continuation.resume(returning: self.session.isRunning)
      }
    }
  }

  /// Frames the delegate has actually received. 0 until the first buffer lands,
  /// which is the has-anything-arrived probe `MicLiveness` short-circuits on.
  ///
  /// A raw frame count rather than the seconds-since-`record()` the retired
  /// `AVAudioRecorder` reported: the only consumer asks whether it has moved off
  /// zero, so dividing by the sample rate manufactured a duration nothing read
  /// as one.
  var deliveredFrames: Int {
    state.withLock { $0.frameCount }
  }

  /// The capture connection's average input power in dBFS
  /// (`AVCaptureAudioChannel.averagePowerLevel`), feeding both the liveness
  /// gate's silence-floor probe and the overlay meter. A missing connection or
  /// channel answers -160 — reads as digital silence, so the gate keeps
  /// waiting (and fails closed at its cap) and the meter rests, the
  /// conservative direction for both.
  ///
  /// The channel itself has a second not-yet-ready value, measured on AirPods:
  /// until its first update it reports `-Float.greatestFiniteMagnitude`
  /// (~-3.4e38), which can arrive *after* the first frames do. Both consumers
  /// take it as silence — `MicLiveness` keeps waiting, `linearLevel` floors —
  /// so it needs no clamping here, but a caller that reads the meter the instant
  /// frames appear will see it.
  func meteredPowerDB() -> Float {
    guard let channel = output.connection(with: .audio)?.audioChannels.first else { return -160 }
    return channel.averagePowerLevel
  }

  /// End capture and hand back everything recorded as raw S16LE PCM at the
  /// dictation API's rate, releasing the device.
  ///
  /// Non-throwing, unlike the seam this replaces: the bytes are already in
  /// memory in the upload encoding, so there is no read-back, decode or temp
  /// file left to fail at.
  ///
  /// Synchronous, unlike `record()`, on two grounds. `stopRunning()` measures
  /// 19–41 ms against the open's ~600 ms, which is not worth another suspension
  /// point on the release path the transcript waits behind; and it cannot race
  /// the `sessionQueue` work, because every caller runs on a recorder whose
  /// `record()` has already resumed (an abandoned bring-up tears down only after
  /// the open returns). If a stop ever does need to overlap an open, it belongs
  /// on `sessionQueue` too — that is what the queue is for.
  func stopAndReadPCM() -> Data {
    session.stopRunning()
    return state.withLock { $0.captured }
  }

  /// End capture and throw the audio away, releasing the device — the teardown
  /// behind a failed `record()`, an aborted bring-up, and a cancel.
  func stopAndDiscard() {
    session.stopRunning()
    state.withLock {
      $0.captured = Data()
      $0.frameCount = 0
    }
  }
}

extension CaptureSessionRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
  /// Sample buffers, on `delegateQueue`: copy the converted S16LE bytes out of
  /// the block buffer and account the frames, under the lock. A buffer whose
  /// bytes can't be copied is dropped whole — better a short gap than a blob
  /// whose byte count and frame count disagree.
  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    let length = CMBlockBufferGetDataLength(blockBuffer)
    guard length > 0 else { return }
    var chunk = Data(count: length)
    let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
      // Empty is excluded above, so a nil base can't happen; answered as a
      // plain non-noErr status rather than trapping, since dropping the buffer
      // is this method's failure mode for every other copy problem too.
      guard let base = raw.baseAddress else { return OSStatus(-1) }
      return CMBlockBufferCopyDataBytes(
        blockBuffer, atOffset: 0, dataLength: length, destination: base)
    }
    guard status == kCMBlockBufferNoErr else { return }
    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    state.withLock {
      $0.captured.append(chunk)
      $0.frameCount += frames
    }
  }
}
