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

  /// Internal, not private, so `StreamingPCMPlayerTests` can bound the drain by it
  /// rather than restate it.
  static let drainSlack = Duration.seconds(2)

  /// The longest one poll of `drain` sleeps, so the drain can overrun its
  /// deadline by at most this much. Internal for the same reason.
  static let drainPollCeiling = Duration.milliseconds(100)

  private let renderer = AVSampleBufferAudioRenderer()
  private let synchronizer = AVSampleBufferRenderSynchronizer()
  private let format: CMAudioFormatDescription?
  private let sampleRate: Int32
  private let rate: Double
  /// What `drain`'s deadline is measured on and its polls sleep on; a test's
  /// `TestClock` steps it, so the bound is checked exactly rather than timed.
  private let clock: any Clock<Duration>
  private let state: Mutex<State>

  /// Seconds of audio queued ahead of what's playing, in listening time (the
  /// rate applied), or 0 once stopped — how far ahead of the listener the
  /// reading has got.
  var bufferedSeconds: Double { (remaining() ?? 0) / rate }

  /// Seconds of audio queued ahead of what's playing, in the audio's own time,
  /// or 0 once stopped. A late chunk's lead is silence never written to a
  /// clip, so it isn't counted.
  var unplayedAudioSeconds: Double { onTimeline { $0.unplayed(now: $1) } ?? 0 }

  /// The loudness of what's playing right now, 0...1, or 0 between words,
  /// before the first chunk, and once stopped. Reads the media clock, so it
  /// follows the audio coming out of the speakers, not the audio arriving.
  var currentLevel: Float {
    state.withLock { state in
      guard !state.stopped else {
        return 0
      }
      let now = CMTimeGetSeconds(synchronizer.currentTime())
      // Windows are in time order, so only the head can have expired.
      if let live = state.levels.firstIndex(where: { $0.end > now }) {
        state.levels.removeFirst(live)
      } else {
        state.levels.removeAll()
      }
      guard let window = state.levels.first, window.start <= now else {
        return 0
      }
      return window.level
    }
  }

  init(sampleRate: Int, rate: Double = 1, clock: any Clock<Duration> = ContinuousClock()) {
    self.sampleRate = Int32(sampleRate)
    self.clock = clock
    // `drain` divides by the rate, and a zero one is an infinite `Duration`,
    // which traps. The store never produces one; this guards new callers.
    self.rate = rate.isFinite && rate > 0 ? rate : 1
    self.state = Mutex(State(schedule: PCMSchedule(sampleRate: sampleRate, rate: self.rate)))
    // Signed 16-bit packed mono, little-endian as the host is: the TTS wire format.
    let wire = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true
    )
    self.format = wire?.formatDescription
    renderer.audioTimePitchAlgorithm = .timeDomain
    synchronizer.addRenderer(renderer)
  }

  private static func sampleBuffer(
    _ pcm: Data, frames: Int, format: CMAudioFormatDescription, at time: CMTime
  ) -> CMSampleBuffer? {
    let length = frames * 2
    var block: CMBlockBuffer?
    guard
      unsafe CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: length,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: length,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &block
      ) == noErr,
      let block
    else {
      return nil
    }
    let copied = unsafe pcm.withUnsafeBytes { raw -> OSStatus in
      guard let base = raw.baseAddress else {
        return -1
      }
      return unsafe CMBlockBufferReplaceDataBytes(
        with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length
      )
    }
    guard copied == noErr else {
      return nil
    }
    var buffer: CMSampleBuffer?
    guard
      unsafe CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: block,
        formatDescription: format,
        sampleCount: frames,
        presentationTimeStamp: time,
        packetDescriptions: nil,
        sampleBufferOut: &buffer
      ) == noErr
    else {
      return nil
    }
    return buffer
  }

  func enqueue(_ pcm: Data) {
    let frames = pcm.count / 2
    guard frames > 0, let format else {
      return
    }
    // Loudness per meter tick, measured before taking the lock the meter and
    // the pacing both wait on; only the placement needs it.
    let window = Int(Double(sampleRate) * MicCapture.meterIntervalSeconds)
    let levels = PCMLevel.levels(of: pcm, windowFrames: window)
    state.withLock { state in
      guard !state.stopped else {
        return
      }
      let first = !state.schedule.started
      let at = state.schedule.place(frames: frames, now: CMTimeGetSeconds(synchronizer.currentTime()))
      for (index, level) in levels.enumerated() {
        let start = at + Double(index * window) / Double(sampleRate)
        let end = min(start + Double(window) / Double(sampleRate), at + Double(frames) / Double(sampleRate))
        state.levels.append(LevelWindow(start: start, end: end, level: level))
      }
      let time = CMTime(seconds: at, preferredTimescale: sampleRate)
      guard let buffer = Self.sampleBuffer(pcm, frames: frames, format: format, at: time) else {
        return
      }
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
    // Copied to a local first: the compiler opens an existential local at a
    // generic call, but not a class's stored property.
    let opened = clock
    await drain(on: opened)
  }

  /// Generic over the clock so its instants compare; `clock`, an existential,
  /// is opened at the call.
  private func drain(on clock: some Clock<Duration>) async {
    let queued = remaining() ?? 0
    let deadline = clock.now.advanced(by: .seconds(queued / rate) + Self.drainSlack)
    while clock.now < deadline {
      guard let remaining = remaining(), remaining > 0 else { break }
      let poll = min(Self.drainPollCeiling, .milliseconds(Int(remaining / rate * 1_000) + 10))
      try? await clock.sleep(for: poll)
      if Task.isCancelled { break }
    }
    stop()
  }

  /// Seconds of the timeline still ahead of the clock, or nil once stopped.
  private func remaining() -> Double? { onTimeline { $0.remaining(now: $1) } }

  /// `read` of the schedule at the clock's current time, or nil once stopped.
  private func onTimeline(_ read: (PCMSchedule, Double) -> Double) -> Double? {
    state.withLock { state in
      state.stopped ? nil : read(state.schedule, CMTimeGetSeconds(synchronizer.currentTime()))
    }
  }

  /// Silences playback at once and discards anything queued. Idempotent.
  func stop() {
    state.withLock { state in
      guard !state.stopped else {
        return
      }
      state.stopped = true
      synchronizer.setRate(0, time: synchronizer.currentTime())
      renderer.flush()
      state.levels.removeAll()
    }
  }
}
