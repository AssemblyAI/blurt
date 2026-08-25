import AudioToolbox
import Foundation
import Synchronization

/// The pinned-device backend: an AudioQueue input recording 16 kHz / mono /
/// 16-bit S16LE straight into memory, bound to one device by its UID via
/// `kAudioQueueProperty_CurrentDevice` — the per-instance device selection the
/// WAV recorder's API doesn't expose (it always resolves the system default).
/// This is the same capture machinery that recorder wraps, driven one level
/// down, so its semantics carry over: created and primed ahead of `record()`
/// (the warm-up analog of `prepareToRecord()`), a clock and an average-power
/// meter for the liveness gate, and a fresh instance per session.
///
/// Only ever constructed for a *pinned* selection (`MicCapture.makeBackend`).
/// The un-pinned default path stays on `WAVFileRecorder`, untouched.
///
/// Hardware-bound like `MicCapture`, and excluded from the coverage gate for
/// the same reason; its live test rides the `BLURT_LIVE_AUDIO_TESTS` gate in
/// `AudioInputDevicesTests`.
///
/// `@unchecked Sendable`: the capture-path confinement argument on
/// `CaptureRecorder` covers the queue handle (created in `init`, immutable
/// after), and everything the CoreAudio callback thread also touches lives in
/// `SharedState` behind a `Mutex`.
final class PinnedAudioQueueRecorder: CaptureRecorder, @unchecked Sendable {
  /// The state the CoreAudio callback thread and the capture path share. A
  /// separate object — not `self` — so the C callback's context pointer exists
  /// before the queue does, and `init` never has to hand out a half-built
  /// `self`. Passed unretained: the recorder owns it for its whole life and
  /// disposes the queue (synchronously) before either is released, so no
  /// callback can outlive it.
  private final class SharedState: Sendable {
    let cell = Mutex(Guarded())
  }

  private struct Guarded {
    /// Every byte the callback has delivered, in arrival order — already the
    /// raw S16LE blob `stopAndReadPCM` returns, so there is no file and no
    /// decode pass on the release path.
    var captured = Data()
    /// True between a successful `record()` and the teardown; the callback
    /// re-enqueues its buffer only while this holds, so a buffer can't be
    /// handed back to a queue that is stopping.
    var running = false
    /// Whether the queue has been stopped and disposed — teardown is reachable
    /// from three methods plus `deinit`, and must run once.
    var disposed = false
  }

  private let queue: AudioQueueRef
  private let shared: SharedState

  /// Creates the queue bound to `deviceUID`, enables metering, and primes the
  /// capture buffers — the prepare-ahead work, so a warm instance makes
  /// `record()` cheap. Throws `AudioQueueError` when any CoreAudio call
  /// refuses (an unknown UID surfaces here, on the device property).
  init(deviceUID: String) throws {
    var format = Self.captureFormat
    let shared = SharedState()
    var created: AudioQueueRef?
    // A literal closure, not a `Self.handleInput` reference: a C function
    // pointer can only be formed from a top-level `func` or a capture-free
    // closure literal — a static-method *reference* is rejected — so the
    // literal forwards to the static implementation (calling it is fine;
    // naming the type is not a capture). It drops the packet timing/description
    // arguments on the way: raw LPCM never needs them.
    try Self.check(
      AudioQueueNewInput(
        &format,
        { userData, queue, buffer, _, _, _ in
          PinnedAudioQueueRecorder.handleInput(userData: userData, queue: queue, buffer: buffer)
        },
        Unmanaged.passUnretained(shared).toOpaque(),
        nil, nil, 0, &created),
      "AudioQueueNewInput")
    guard let created else {
      throw AudioQueueError(operation: "AudioQueueNewInput returned no queue", status: noErr)
    }
    do {
      // The pin itself. Must land before the queue starts; a UID that no longer
      // resolves is refused here, which `MicCapture.resolveInput` pre-empts by
      // falling back to the system default when the device is absent. The
      // property's value is the CFString reference itself, handed over through
      // `withUnsafeMutablePointer` — a bare `&uid` is refused ("forming
      // 'UnsafeRawPointer' to a variable of type 'CFString'") because the type
      // carries an object reference; same pattern as `AudioInputDevices`'
      // UID-translation qualifier.
      var uid = deviceUID as CFString
      try withUnsafeMutablePointer(to: &uid) { pointer in
        try Self.check(
          AudioQueueSetProperty(
            created, kAudioQueueProperty_CurrentDevice, pointer,
            UInt32(MemoryLayout<CFString>.size)),
          "AudioQueueSetProperty(CurrentDevice)")
      }
      var meteringEnabled: UInt32 = 1
      try Self.check(
        AudioQueueSetProperty(
          created, kAudioQueueProperty_EnableLevelMetering, &meteringEnabled,
          UInt32(MemoryLayout<UInt32>.size)),
        "AudioQueueSetProperty(EnableLevelMetering)")
      // An input queue captures only into buffers already enqueued, so priming
      // belongs to construction, not to record().
      for _ in 0..<Self.bufferCount {
        var buffer: AudioQueueBufferRef?
        try Self.check(
          AudioQueueAllocateBuffer(created, Self.bufferByteSize, &buffer),
          "AudioQueueAllocateBuffer")
        guard let buffer else {
          throw AudioQueueError(operation: "AudioQueueAllocateBuffer returned no buffer", status: noErr)
        }
        try Self.check(AudioQueueEnqueueBuffer(created, buffer, 0, nil), "AudioQueueEnqueueBuffer")
      }
    } catch {
      // init is the one place teardown can't go through dispose() — self isn't
      // built yet — so the partially configured queue is released right here.
      _ = AudioQueueDispose(created, true)
      throw error
    }
    self.queue = created
    self.shared = shared
  }

  deinit {
    dispose()
  }

  func record() -> Bool {
    // Raised before the start, not after: the first callback can land while
    // AudioQueueStart is still on this stack, and it must already see running
    // to re-enqueue its buffer. Lowered again on refusal — nothing started.
    shared.cell.withLock { $0.running = true }
    guard AudioQueueStart(queue, nil) == noErr else {
      shared.cell.withLock { $0.running = false }
      return false
    }
    return true
  }

  /// The queue's timeline in seconds, or 0 while it isn't started or has no
  /// valid sample time yet. Frames of digital silence advance it like real
  /// audio — the liveness gate's power term is what tells those apart.
  var currentTime: TimeInterval {
    var timestamp = AudioTimeStamp()
    let status = AudioQueueGetCurrentTime(queue, nil, &timestamp, nil)
    guard status == noErr, timestamp.mFlags.contains(.sampleTimeValid) else { return 0 }
    return max(0, timestamp.mSampleTime / Self.captureFormat.mSampleRate)
  }

  /// The queue's average input power in dBFS. A failed read answers -160 — the
  /// digital-silence floor — which is the conservative direction for both
  /// consumers: the liveness gate keeps waiting (and fails closed at its cap)
  /// rather than declaring a device live on no evidence, and the meter rests.
  func meteredPowerDB() -> Float {
    var meter = AudioQueueLevelMeterState()
    var size = UInt32(MemoryLayout<AudioQueueLevelMeterState>.size)
    let status = AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentLevelMeterDB, &meter, &size)
    guard status == noErr else { return -160 }
    return meter.mAveragePower
  }

  func stopAndReadPCM() -> Data {
    dispose()
    return shared.cell.withLock { $0.captured }
  }

  func stopAndDiscard() {
    dispose()
    shared.cell.withLock { $0.captured = Data() }
  }

  var logName: String { "pinned input queue" }

  /// Idempotent teardown: the first caller stops the queue synchronously —
  /// after which no callback runs — and disposes it; later callers (and
  /// `deinit`, which backstops a recorder dropped without a stop) find
  /// `disposed` set and do nothing.
  private func dispose() {
    let alreadyDisposed = shared.cell.withLock { guarded in
      let was = guarded.disposed
      guarded.running = false
      guarded.disposed = true
      return was
    }
    guard !alreadyDisposed else { return }
    _ = AudioQueueStop(queue, true)
    _ = AudioQueueDispose(queue, true)
  }

  /// The capture callback, on a CoreAudio-owned thread: append what the buffer
  /// carries and hand the buffer back while the session is still running. It
  /// touches nothing but `SharedState`, under its lock. Called through the
  /// closure literal in `init` (see there for why it can't be passed directly).
  private static func handleInput(
    userData: UnsafeMutableRawPointer?, queue: AudioQueueRef, buffer: AudioQueueBufferRef
  ) {
    guard let userData else { return }
    let shared = Unmanaged<SharedState>.fromOpaque(userData).takeUnretainedValue()
    let byteCount = Int(buffer.pointee.mAudioDataByteSize)
    let stillRunning = shared.cell.withLock { guarded in
      if byteCount > 0 {
        guarded.captured.append(Data(bytes: buffer.pointee.mAudioData, count: byteCount))
      }
      return guarded.running
    }
    guard stillRunning else { return }
    _ = AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
  }

  private static func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioQueueError(operation: operation, status: status) }
  }

  /// The dictation API's geometry — the same 16 kHz mono S16LE the WAV path
  /// records — asked of the queue directly, which converts from the hardware
  /// format on the fly exactly as the WAV recorder does. Derived from
  /// `SyncSTTLimits` so the two backends can't drift apart.
  private static var captureFormat: AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: Double(SyncSTTLimits.sampleRate),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: UInt32(SyncSTTLimits.bytesPerSample),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(SyncSTTLimits.bytesPerSample),
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0)
  }

  /// 100 ms of audio per buffer, three in flight — small enough that the meter
  /// and the captured tail stay fresh, large enough that the callback isn't hot.
  private static var bufferByteSize: UInt32 {
    UInt32(SyncSTTLimits.sampleRate * SyncSTTLimits.bytesPerSample / 10)
  }

  private static let bufferCount = 3
}
