import AVFoundation
import Synchronization

/// Plays PCM16 LE mono chunks as they arrive, using an
/// `AVSampleBufferAudioRenderer` driven by a render synchronizer.
///
/// Why this API: `AVAudioPlayer` needs the whole file before it can start, which
/// would delay the first word until the last one is synthesized, and
/// `AVAudioEngine` is ruled out repo-wide (see the audio guardrails). A sample
/// buffer renderer takes timestamped buffers as they come and plays them on the
/// synchronizer's clock.
///
/// Where each chunk lands on the timeline is `PCMSchedule`'s call; this class is
/// only the AV shell around it.
///
/// **Faster speech is the synchronizer's rate**, not a request to the TTS
/// service. The renderer's time-domain pitch algorithm (Apple's choice for
/// voice) keeps the pitch while the clock runs `rate` times faster, so work
/// mode's double speed costs nothing on the wire and starts as soon as the first
/// chunk does. Measured 2026-10-02: at rate 2 the media clock ran ~1.8x the wall
/// clock over its first 0.8 s, start-up latency included, with no renderer
/// error.
///
/// Thread-safe: `enqueue`, `stop` and `drain` can be called from any context.
/// All mutable state sits behind one `Mutex`; `@unchecked` covers the AV objects,
/// which are only touched inside that lock (or, for the synchronizer clock read
/// and `addRenderer` at init, through APIs AVFoundation documents as thread-safe).
final class StreamingPCMPlayer: PCMSink, @unchecked Sendable {
  /// One 50 ms window's loudness and where it sits on the media timeline.
  private struct LevelWindow {
    let start: Double
    let end: Double
    let level: Float
  }

  private struct State {
    var schedule: PCMSchedule
    var stopped = false
    /// Each queued 50 ms window's loudness and where it sits on the media
    /// timeline, oldest first, for `currentLevel`.
    var levels: [LevelWindow] = []
  }

  private let renderer = AVSampleBufferAudioRenderer()
  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private let format: CMAudioFormatDescription?
  private let sampleRate: Int32
  private let rate: Double
  private let state: Mutex<State>

  init(sampleRate: Int, rate: Double = 1) {
    self.sampleRate = Int32(sampleRate)
    // `drain` divides by the rate, and a zero one is an infinite `Duration`,
    // which traps. The store never produces one; this guards new callers.
    self.rate = rate.isFinite && rate > 0 ? rate : 1
    self.state = Mutex(State(schedule: PCMSchedule(sampleRate: sampleRate, rate: self.rate)))
    var description = AudioStreamBasicDescription(
      mSampleRate: Float64(sampleRate),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    self.format = format
    renderer.audioTimePitchAlgorithm = .timeDomain
    synchronizer.addRenderer(renderer)
  }

  func enqueue(_ pcm: Data) {
    let frames = pcm.count / 2
    guard frames > 0, let format else { return }
    // Loudness per meter tick, measured before taking the lock the meter and
    // the pacing both wait on; only the placement needs it.
    let window = Int(Double(sampleRate) * MicCapture.meterIntervalSeconds)
    let levels = PCMLevel.levels(of: pcm, windowFrames: window)
    state.withLock { state in
      guard !state.stopped else { return }
      let first = !state.schedule.started
      let at = state.schedule.place(frames: frames, now: CMTimeGetSeconds(synchronizer.currentTime()))
      for (index, level) in levels.enumerated() {
        let start = at + Double(index * window) / Double(sampleRate)
        let end = min(start + Double(window) / Double(sampleRate), at + Double(frames) / Double(sampleRate))
        state.levels.append(LevelWindow(start: start, end: end, level: level))
      }
      let time = CMTime(seconds: at, preferredTimescale: sampleRate)
      guard let buffer = Self.sampleBuffer(pcm, frames: frames, format: format, at: time) else { return }
      renderer.enqueue(buffer)
      if first { synchronizer.setRate(Float(rate), time: .zero) }
    }
  }

  /// Returns once everything enqueued has been played, or once `stop()` is called.
  ///
  /// Also bounded by the wall clock: the audio still queued, played at `rate`,
  /// plus `drainSlack`. The
  /// synchronizer's clock only advances while an output device is consuming
  /// audio. With no device at all (a headless Mac, or one whose output vanished
  /// mid-read), "remaining" would never reach zero, and the press would stay in
  /// read-aloud mode until the user pressed again.
  func drain() async {
    let queued = remaining() ?? 0
    let deadline = ContinuousClock.now + .seconds(queued / rate) + Self.drainSlack
    while ContinuousClock.now < deadline {
      guard let remaining = remaining(), remaining > 0 else { break }
      try? await Task.sleep(for: .milliseconds(min(100, Int(remaining / rate * 1000) + 10)))
      if Task.isCancelled { break }
    }
    stop()
  }

  private static let drainSlack = Duration.seconds(2)

  /// Seconds of audio queued ahead of what's playing, in listening time (the
  /// rate applied), or 0 once stopped — how far ahead of the listener the
  /// reading has got.
  var bufferedSeconds: Double { (remaining() ?? 0) / rate }

  /// Seconds of audio still ahead of the clock, or nil once stopped.
  private func remaining() -> Double? {
    state.withLock { state in
      state.stopped ? nil : state.schedule.remaining(now: CMTimeGetSeconds(synchronizer.currentTime()))
    }
  }

  /// The loudness of what's playing right now, 0...1, or 0 between words,
  /// before the first chunk, and once stopped. Reads the media clock, so it
  /// follows the audio coming out of the speakers, not the audio arriving.
  var currentLevel: Float {
    state.withLock { state in
      guard !state.stopped else { return 0 }
      let now = CMTimeGetSeconds(synchronizer.currentTime())
      // Windows are in time order, so only the head can have expired.
      if let live = state.levels.firstIndex(where: { $0.end > now }) {
        state.levels.removeFirst(live)
      } else {
        state.levels.removeAll()
      }
      guard let window = state.levels.first, window.start <= now else { return 0 }
      return window.level
    }
  }

  /// Silences playback at once and discards anything queued. Idempotent.
  func stop() {
    state.withLock { state in
      guard !state.stopped else { return }
      state.stopped = true
      synchronizer.setRate(0, time: synchronizer.currentTime())
      renderer.flush()
      state.levels.removeAll()
    }
  }

  private static func sampleBuffer(
    _ pcm: Data, frames: Int, format: CMAudioFormatDescription, at time: CMTime
  ) -> CMSampleBuffer? {
    let length = frames * 2
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
      let block
    else { return nil }
    let copied = pcm.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else { return -1 }
      return CMBlockBufferReplaceDataBytes(
        with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    }
    guard copied == noErr else { return nil }
    var buffer: CMSampleBuffer?
    guard
      CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: frames, presentationTimeStamp: time, packetDescriptions: nil,
        sampleBufferOut: &buffer) == noErr
    else { return nil }
    return buffer
  }
}

/// Where `SelectionSpeaker` sends audio. `StreamingPCMPlayer` is the production
/// conformance. The tests substitute a recorder, since a real sink needs an
/// output device.
protocol PCMSink: Sendable {
  func enqueue(_ pcm: Data)
  /// Returns once everything enqueued has played, or `stop()` was called.
  func drain() async
  /// Silences at once. Idempotent.
  func stop()
  /// The loudness of what's playing now, 0...1, for the pill's meter.
  var currentLevel: Float { get }
  /// Seconds of audio queued ahead of what's playing, in listening time.
  var bufferedSeconds: Double { get }
}

extension PCMSink {
  var currentLevel: Float { 0 }
  var bufferedSeconds: Double { 0 }
}
