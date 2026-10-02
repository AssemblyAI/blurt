@preconcurrency import AVFoundation
import CoreMedia
import Dispatch
import Foundation
import Synchronization

/// The capture backend (owner-directed move to `AVCaptureSession`, 2026-08-25):
/// a session built fresh per capture around a single audio device — the device
/// pinned in Settings when one is set, the system default otherwise — whose data
/// output converts to the dictation API's 16 kHz mono 16-bit LPCM on the fly and
/// delivers it here as sample buffers, published straight onto `frames` for the
/// upload to drain and tallied by byte count. No temp file, no resample pass, no
/// decode on the release path — and no second copy of the utterance held in
/// memory, because the bytes leave as they arrive.
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
/// Building the session does **not** engage the microphone: measured against
/// CoreAudio's own `kAudioDevicePropertyDeviceIsRunningSomewhere`, the bit
/// behind the input indicator, it stays clear until `record()`. Building is also
/// cheap next to opening. `MicCapture.warmUp()` holds the full measurement and
/// what follows from it (no warm-recorder lifecycle, and nothing worth
/// pre-paying but the process's first touch).
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
    /// How many bytes the delegate has delivered. A count, not the bytes: the
    /// recording goes out on `frames` as it is captured, so nothing downstream
    /// reads the audio back — the release path only needs to know whether there
    /// was enough of it to send (`SyncSTTLimits.minPCMBytes`). Accumulating the
    /// blob as well cost a second `memcpy` of every byte inside this lock, plus
    /// `Data`'s geometric reallocation, and retained a duplicate of the whole
    /// utterance (~3.7 MB at the recording cap) until release.
    var capturedBytes = 0
    /// Frames delivered so far, summed off each sample buffer's own count.
    /// Frames of digital silence count exactly like real audio; the liveness
    /// gate's power term is what tells those apart.
    var frameCount = 0
  }

  /// The live feed of captured audio, in arrival order — handed out as it lands
  /// so the dictation request can upload it while the user is still speaking.
  /// Nothing is kept behind it; `Guarded.capturedBytes` only counts what went
  /// past.
  ///
  /// One stream per recorder, which is exactly one per capture: the recorder is
  /// built fresh for every press (see the type's own note on why), so a stream
  /// can never carry two utterances' audio and there is nothing to reset
  /// between presses. It exists from `init`, before `record()` opens the
  /// device, so no frame can be delivered before there is somewhere to put it —
  /// including the ones the liveness gate waits for.
  ///
  /// Unbounded, but a handoff rather than a buffer: the upload's body producer
  /// drains it eagerly (it yields onward into an unbounded stream, and an
  /// unbounded yield never suspends), so a slow uplink backs up *there*, not
  /// here. And once the request ends the producer is cancelled, which terminates
  /// this stream — later yields are dropped rather than accumulated. So no
  /// backlog forms in this stage at all; check `streamedBody` for the one that
  /// does.
  let frames: AsyncStream<Data>
  private let framesContinuation: AsyncStream<Data>.Continuation

  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  /// The serial queue sample buffers are delivered on; only the delegate
  /// method runs here, and it touches nothing but `state`.
  private let delegateQueue = DispatchQueue(
    label: HostIdentity.current.queueLabel("MicCaptureSession"))
  /// The serial queue session *control* runs on — building and starting —
  /// deliberately not `delegateQueue`. Both steps block for as long as the
  /// hardware takes, and blocking the delivery queue would stall the very frames
  /// the liveness gate is then waiting for. A `DispatchQueue` rather than a
  /// detached `Task`, so those waits park a Dispatch thread instead of one of the
  /// cooperative pool's — the pool is what the rest of the press runs on (the
  /// context capture that overlaps this, the transcriber's connection warm-up),
  /// and starving it is how covering the retired backend in CI deadlocked the
  /// whole test run.
  ///
  /// `static`, so it also serializes across recorders: only one capture session
  /// is ever meant to be coming up at a time, and AVFoundation asks that session
  /// control be serialized rather than concurrent.
  private static let controlQueue = DispatchQueue(
    label: HostIdentity.current.queueLabel("MicCaptureSessionControl"))
  private let state = Mutex(Guarded())

  /// Builds a recorder off the caller's executor, on `controlQueue`.
  ///
  /// The build is not free and not bounded: ~5 ms warm, but ~185 ms the first
  /// time a process touches AVFoundation's capture stack (~90–125 ms of that the
  /// first device query alone). Run inline on `MicCapture` it blocked the actor
  /// for that whole window, which a teardown racing the bring-up then waited out
  /// — the same defect as a blocking `record()`, and `MicCaptureBringUpTests`
  /// caught it at 100 ms once its own warm-up probe was removed. Both hops run
  /// on `controlQueue`.
  ///
  /// Deliberately still *separate* from `record()` rather than folded into one
  /// "make and start" hop: that building leaves the microphone closed is the
  /// invariant the whole warm-up design rests on, and the live suite can only
  /// assert it while the two steps are observable apart.
  static func make(pinnedUID: String?) async throws -> CaptureSessionRecorder {
    try await withCheckedThrowingContinuation { continuation in
      controlQueue.async {
        continuation.resume(with: Result { try CaptureSessionRecorder(pinnedUID: pinnedUID) })
      }
    }
  }

  /// Builds and fully configures the session — device input, converted-format
  /// data output, delegate — without starting it. Private: `make` is the entry
  /// point, so no caller can put this back on its own executor. Throws only when
  /// `AVCaptureDeviceInput` refuses the device (e.g. no microphone
  /// authorization); "no device at all" instead leaves the session inputless,
  /// so `record()` answers false and `MicCapture.start()` surfaces the same
  /// `.audioCaptureFailed(noInputDevice)` it always has.
  private init(pinnedUID: String?) throws {
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    frames = stream
    framesContinuation = continuation
    super.init()

    session.beginConfiguration()
    defer { session.commitConfiguration() }
    if let device = Self.device(forPinnedUID: pinnedUID) {
      let input = try AVCaptureDeviceInput(device: device)
      if session.canAddInput(input) {
        session.addInput(input)
      } else {
        // Leaves the session inputless, so `record()` answers false and the press
        // surfaces `.audioCaptureFailed(noInputDevice)` — correct, but silent
        // without this: "no usable input device" for a device that exists and was
        // refused is the one case that log line can't explain on its own.
        MicCapture.logger.error(
          "session refused the input device \(device.localizedName, privacy: .public)")
      }
    }
    // macOS only: `audioSettings` is not in the iOS SDK, so there the output
    // vends the device's native format — an iOS host brings its own capture.
    #if os(macOS)
      output.audioSettings = Self.audioSettings()
    #endif
    output.setSampleBufferDelegate(self, queue: delegateQueue)
    if session.canAddOutput(output) {
      session.addOutput(output)
    } else {
      // Without an output nothing is ever delivered, so the liveness gate would
      // fail closed at its cap with no clue why.
      MicCapture.logger.error("session refused the audio data output")
    }
  }

  deinit {
    // Backstop for a recorder dropped without a stop, so an orphaned instance
    // can't keep the microphone engaged for the rest of the process — and so a
    // consumer awaiting `frames` can't be left hanging on a stream nothing will
    // ever feed again.
    if session.isRunning {
      session.stopRunning()
    }
    framesContinuation.finish()
  }

  /// The device the session records from: the pinned device when its UID still
  /// resolves (`AVCaptureDevice.uniqueID` is the CoreAudio device UID on
  /// macOS, the same string `MicDeviceStore` persists), else the default input
  /// — the same per-capture fallback `MicCapture.resolveInput` applies, kept
  /// here too so the race where the device vanishes between resolution and
  /// build degrades identically. Nil when the machine has no input at all.
  private static func device(forPinnedUID pinnedUID: String?) -> AVCaptureDevice? {
    if let pinnedUID, let pinned = AudioInputDevices.device(forUID: pinnedUID) {
      return pinned
    }
    return AudioInputDevices.systemDefaultDevice
  }

  /// Opens the device and starts capture, answering false when there is no
  /// usable input: nothing was attached at build time, or the session refused to
  /// run.
  ///
  /// This is where the route-activation cost lives, all of it — ~180 ms on the
  /// built-in mic, ~600 ms on a USB interface, and on AirPods ~80 ms before
  /// `startRunning()` returns plus ~400 ms before the first frame. It is `async`
  /// and hops to `controlQueue` precisely because that cost is unbounded from the
  /// caller's point of view: run inline it blocked `MicCapture` for the whole
  /// open, and a teardown arriving in that window measured 578 ms of waiting on a
  /// 635 ms open (`MicCaptureBringUpTests`). Suspending instead of blocking means
  /// the actor stays available to the stop and cancel that may be racing this.
  ///
  /// The suspension is why `MicCapture.start()` snapshots `stopGeneration`
  /// before the bring-up and re-checks after: a teardown can land during the
  /// open, and it has to win.
  func record() async -> Bool {
    guard !session.inputs.isEmpty else { return false }
    return await withCheckedContinuation { continuation in
      Self.controlQueue.async {
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

  /// The loudest of the capture connection's channels, in dBFS
  /// (`AVCaptureAudioChannel.averagePowerLevel`), feeding both the liveness
  /// gate's silence-floor probe and the overlay meter. A missing connection or
  /// channel answers -160 — reads as digital silence, so the gate keeps
  /// waiting (and fails closed at its cap) and the meter rests, the
  /// conservative direction for both.
  ///
  /// The **loudest**, not the first, and this is load-bearing:
  /// `connection.audioChannels` describes the *device's* channels, not the mono
  /// the data output converts to. Measured on this machine — a stereo interface,
  /// an aggregate and two virtual devices all report `audioChannels=2` against
  /// `outputChannels=1`, and a channel carrying nothing reads -758 dBFS. So
  /// metering channel 0 alone reported silence for any device whose microphone
  /// sits on input 2 (a 2-in interface with the mic in the second socket, or an
  /// aggregate whose first sub-device is silent) while the recorded mono had full
  /// signal: the liveness gate never confirmed and the press failed **closed**
  /// with "The microphone didn't start." on a mic that records perfectly. The
  /// retired `AVAudioRecorder.averagePower(forChannel: 0)` metered the recorded
  /// mono downmix, so channel 0 was the whole picture there — this was a behavior
  /// change that rode inside the backend swap unnoticed.
  ///
  /// A max slightly over-reads the true downmix (one loud channel of two averages
  /// quieter once mixed), which is the harmless direction for a floor probe and
  /// for bars.
  ///
  /// The channel itself has a second not-yet-ready value, measured on AirPods:
  /// until its first update it reports `-Float.greatestFiniteMagnitude`
  /// (~-3.4e38), which can arrive *after* the first frames do. Both consumers
  /// take it as silence — `MicLiveness` keeps waiting, `linearLevel` floors —
  /// so it needs no clamping here, but a caller that reads the meter the instant
  /// frames appear will see it.
  func meteredPowerDB() -> Float {
    let channels = output.connection(with: .audio)?.audioChannels ?? []
    guard !channels.isEmpty else { return -160 }
    return channels.reduce(-Float.infinity) { max($0, $1.averagePowerLevel) }
  }

  /// End capture and report how many bytes it produced, releasing the device.
  /// The audio itself went out on `frames` as it arrived — see this type's
  /// summary — so there is nothing here to hand back.
  ///
  /// Non-throwing, unlike the seam this replaces: a tally cannot fail, and there
  /// is no read-back, decode or temp file left to fail at either.
  ///
  /// Synchronous, unlike `make` and `record()`, on two grounds. `stopRunning()`
  /// measures 19–41 ms against the open's ~600 ms, which is not worth another
  /// suspension point on the release path the transcript waits behind; and it
  /// cannot race the `controlQueue` work, because every caller runs on a recorder
  /// whose `record()` has already resumed (an abandoned bring-up tears down only
  /// after the open returns). If a stop ever does need to overlap an open, it
  /// belongs on `controlQueue` too — that is what the queue is for.
  /// Finishing `frames` here is what closes the upload's multipart body: the
  /// transcriber writes the `config` part and the closing boundary as soon as
  /// the stream ends, so "the recording stopped" and "the request body is
  /// complete" are the same event.
  ///
  /// Answers the byte count rather than the audio, because by here the audio has
  /// already been uploaded — see `Guarded.capturedBytes`.
  func stopAndReadByteCount() -> Int {
    session.stopRunning()
    // Finish and count under one lock, so the feed and the count cut off at the
    // same chunk. A delegate callback still waiting on the lock then lands after
    // both — its bytes reach neither, which is consistent, and it is
    // post-`stopRunning()` audio in the first place.
    return state.withLock {
      framesContinuation.finish()
      return $0.capturedBytes
    }
  }

  /// End capture and throw the audio away, releasing the device — the teardown
  /// behind a failed `record()`, an aborted bring-up, and a cancel.
  ///
  /// The same mechanism as `stopAndReadByteCount`, whose result it drops. It
  /// used to differ by clearing the captured blob, which released megabytes;
  /// with a byte count there is nothing to release, and zeroing the tallies
  /// would be a dead store — the recorder is one per capture and every caller
  /// drops it immediately. Kept as its own name because the call sites' intent
  /// (there is nothing here worth keeping) is worth stating.
  func stopAndDiscard() {
    _ = stopAndReadByteCount()
  }
}

extension CaptureSessionRecorder {
  /// The block buffer's `length` bytes, copied exactly **once** — this runs on
  /// the audio delivery queue, which this file goes to lengths elsewhere to keep
  /// unblocked.
  ///
  /// Prefers the buffer's own pointer, which needs no destination allocation and
  /// so no zero-fill. `Data(count:)` is documented to hand back *zeroed* bytes,
  /// so the fallback below writes every byte twice — once by the allocator, once
  /// by the copy — a wasted ~32 kB/s memset for the length of the recording.
  /// `CMBlockBufferGetDataPointer` reports how much is contiguous at the offset,
  /// and anything short of the whole length means the buffer is segmented (which
  /// LPCM from this output is not, in practice) and the copying path has to run
  /// rather than be assumed away. Nil when neither read succeeds.
  fileprivate static func copyBytes(from blockBuffer: CMBlockBuffer, length: Int) -> Data? {
    var contiguousLength = 0
    var totalLength = 0
    var pointer: UnsafeMutablePointer<Int8>?
    let located = CMBlockBufferGetDataPointer(
      blockBuffer, atOffset: 0, lengthAtOffsetOut: &contiguousLength,
      totalLengthOut: &totalLength, dataPointerOut: &pointer)
    if located == kCMBlockBufferNoErr, let pointer, contiguousLength >= length {
      return Data(bytes: pointer, count: length)
    }
    var copied = Data(count: length)
    let status = copied.withUnsafeMutableBytes { raw -> OSStatus in
      // Empty is excluded by the caller, so a nil base can't happen; answered as
      // a plain non-noErr status rather than trapping, since dropping the buffer
      // is this method's failure mode for every other copy problem too.
      guard let base = raw.baseAddress else { return OSStatus(-1) }
      return CMBlockBufferCopyDataBytes(
        blockBuffer, atOffset: 0, dataLength: length, destination: base)
    }
    return status == kCMBlockBufferNoErr ? copied : nil
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
    // A failed read drops the buffer whole rather than appending part of it: a
    // tally and a feed that disagree are worse than a gap.
    guard let chunk = Self.copyBytes(from: blockBuffer, length: length) else { return }
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    state.withLock {
      $0.capturedBytes += chunk.count
      $0.frameCount += frameCount
      // Published *under* the lock, together with the tally, because the two
      // have to agree: `stopAndReadByteCount` finishes the feed and reads the
      // count under this same lock, so a chunk counted here but yielded after
      // that would be measured without being uploaded — and the slice lost that
      // way is exactly the tail the Bluetooth linger exists to preserve. Cheap
      // enough to hold: an unbounded `yield` is a buffer append plus at most one
      // continuation resumption, and it cannot re-enter this lock.
      framesContinuation.yield(chunk)
    }
  }
}
