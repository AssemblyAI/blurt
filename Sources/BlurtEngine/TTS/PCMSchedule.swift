/// Where `StreamingPCMPlayer` puts each chunk on its playback timeline. Split
/// out of the player so the rule is covered by tests, since the player itself
/// only runs against a real output device.
///
/// Each chunk goes right after the previous one. If a chunk arrives after the
/// clock has already passed that point (the network fell behind playback), it
/// goes `lead` into the future instead. Otherwise the renderer would drop it as
/// late and skip audio. A late chunk costs a small gap rather than lost words.
/// The first chunk also gets the lead, so the renderer has it in hand before the
/// clock starts.
///
/// The timeline is in media seconds, which pass `rate` times faster than the
/// wall clock (a read-aloud speed above 1×), so the lead is scaled by the rate to
/// keep the same real headroom.
struct PCMSchedule {
  /// Seconds of real headroom for a first or late chunk.
  static let lead = 0.05

  let sampleRate: Double
  /// The lead in media seconds at this schedule's playback rate.
  let leadTime: Double
  /// Where the next chunk goes, in seconds on the playback timeline.
  private(set) var nextTime = 0.0
  private(set) var started = false
  /// Where the audio since the last lead starts. Only this lead's gap can be
  /// ahead of the clock: a lead is added only once the clock has passed every
  /// chunk before it.
  private var audioStart = 0.0

  init(sampleRate: Int, rate: Double = 1) {
    self.sampleRate = Double(sampleRate)
    self.leadTime = Self.lead * rate
  }

  /// The presentation time for a chunk of `frames`, given the clock reads `now`.
  /// Advances the schedule past the chunk.
  mutating func place(frames: Int, now: Double) -> Double {
    if !started || nextTime < now {
      nextTime = (started ? now : 0) + leadTime
      audioStart = nextTime
    }
    started = true
    let at = nextTime
    nextTime += Double(frames) / sampleRate
    return at
  }

  /// Seconds of the timeline still ahead of the clock, a lead's silence
  /// included: how far ahead of the listener the reading is.
  func remaining(now: Double) -> Double {
    started ? max(0, nextTime - now) : 0
  }

  /// Seconds of audio still ahead of the clock, without a lead's silence:
  /// what was scheduled but not yet heard.
  func unplayed(now: Double) -> Double {
    started ? max(0, nextTime - max(now, audioStart)) : 0
  }
}
