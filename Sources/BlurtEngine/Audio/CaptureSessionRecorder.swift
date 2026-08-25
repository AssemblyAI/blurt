@preconcurrency import AVFoundation
import CoreMedia
import Dispatch
import Foundation
import Synchronization

/// The one capture backend (owner-directed move to `AVCaptureSession`,
/// 2026-08-25): a session built fresh per capture around a single audio device
/// — the device pinned in Settings when one is set, the system default
/// otherwise — whose data output converts to the dictation API's 16 kHz mono
/// 16-bit LPCM on the fly and delivers it here as sample buffers, accumulated
/// in memory as the raw S16LE blob `stopAndReadPCM` returns. No temp file, no
/// resample pass, no decode on the release path.
///
/// Fresh-per-session is load-bearing, exactly as it was for the recorders this
/// replaces: the session's input is attached to one device at build time and
/// never re-resolves, so reuse across a device switch is what `MicCapture`'s
/// warm validation exists to prevent (see `takeWarmRecorder`).
///
/// Building the session does **not** engage the microphone — no capture, no
/// input indicator — which is what makes the warm-up safe to hold idle. The
/// device is only opened by `record()`'s `startRunning()`, so the route
/// activation cost lands inside the press's connecting window (the liveness
/// wait's clock starts *after* `record()` returns, so a slow bring-up eats
/// none of the frame-arrival budget).
///
/// Hardware-bound like `MicCapture`, and excluded from the coverage gate for
/// the same reason; its live test rides the `BLURT_LIVE_AUDIO_TESTS` gate in
/// `AudioInputDevicesTests`.
///
/// `@unchecked Sendable`: the capture-path confinement argument on
/// `CaptureRecorder` covers the session/output handles (configured in `init`,
/// then only read), and everything the delegate queue also touches lives
/// behind the `Mutex`.
final class CaptureSessionRecorder: NSObject, CaptureRecorder, @unchecked Sendable {
  private struct Guarded {
    /// Every byte the delegate has delivered, in arrival order — already the
    /// raw S16LE blob `stopAndReadPCM` returns.
    var captured = Data()
    /// Frames delivered so far, summed off each sample buffer's own count —
    /// the recorder's clock. Frames of digital silence advance it exactly like
    /// real audio; the liveness gate's power term is what tells those apart.
    var capturedSampleCount = 0
  }

  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  /// The serial queue sample buffers are delivered on; only the delegate
  /// method runs here, and it touches nothing but `state`.
  private let delegateQueue = DispatchQueue(
    label: HostIdentity.current.queueLabel("MicCaptureSession"))
  private let state = Mutex(Guarded())
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

  /// Opens the device and starts capture. `startRunning()` is synchronous —
  /// this is where the route-activation cost lives now that warm-up only
  /// pre-builds — and false means no usable input: nothing was attached at
  /// build time, or the session refused to run.
  func record() -> Bool {
    guard !session.inputs.isEmpty else { return false }
    session.startRunning()
    return session.isRunning
  }

  /// Seconds of audio delivered so far — the frames the delegate has actually
  /// received, over the capture rate. 0 until the first buffer lands, which is
  /// the "has the clock moved" probe `MicLiveness` short-circuits on.
  var currentTime: TimeInterval {
    Double(state.withLock { $0.capturedSampleCount }) / Double(SyncSTTLimits.sampleRate)
  }

  /// The capture connection's average input power in dBFS
  /// (`AVCaptureAudioChannel.averagePowerLevel`), feeding both the liveness
  /// gate's silence-floor probe and the overlay meter. A missing connection or
  /// channel answers -160 — reads as digital silence, so the gate keeps
  /// waiting (and fails closed at its cap) and the meter rests, the
  /// conservative direction for both.
  func meteredPowerDB() -> Float {
    guard let channel = output.connection(with: .audio)?.audioChannels.first else { return -160 }
    return channel.averagePowerLevel
  }

  func stopAndReadPCM() -> Data {
    session.stopRunning()
    return state.withLock { $0.captured }
  }

  func stopAndDiscard() {
    session.stopRunning()
    state.withLock {
      $0.captured = Data()
      $0.capturedSampleCount = 0
    }
  }
}

extension CaptureSessionRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
  /// Sample buffers, on `delegateQueue`: copy the converted S16LE bytes out of
  /// the block buffer and account the frames, under the lock. A buffer whose
  /// bytes can't be copied is dropped whole — better a short gap than a blob
  /// whose byte count and sample count disagree.
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
    let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
    state.withLock {
      $0.captured.append(chunk)
      $0.capturedSampleCount += sampleCount
    }
  }
}
