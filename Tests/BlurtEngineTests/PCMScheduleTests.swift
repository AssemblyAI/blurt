import Testing

@testable import BlurtEngine

@Suite("PCMSchedule")
struct PCMScheduleTests {
  /// Timeline math is in `Double` seconds, so compare within a sample's width.
  private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

  @Test("the first chunk starts one lead in, and the next follows it back to back")
  func contiguous() {
    var schedule = PCMSchedule(sampleRate: 1_000)
    #expect(schedule.place(frames: 500, now: 0) == PCMSchedule.lead)
    #expect(near(schedule.place(frames: 500, now: 0.2), PCMSchedule.lead + 0.5))
    #expect(near(schedule.nextTime, PCMSchedule.lead + 1))
  }

  @Test("a chunk that arrives after the clock passed its slot is re-anchored ahead of now")
  func lateChunk() {
    var schedule = PCMSchedule(sampleRate: 1_000)
    _ = schedule.place(frames: 100, now: 0)
    #expect(schedule.place(frames: 100, now: 2) == 2 + PCMSchedule.lead)
  }

  @Test("remaining is the scheduled audio still ahead of the clock, never negative")
  func remaining() {
    var schedule = PCMSchedule(sampleRate: 1_000)
    #expect(schedule.remaining(now: 0) == 0)
    _ = schedule.place(frames: 1_000, now: 0)
    #expect(near(schedule.remaining(now: 0.55), 0.5))
    #expect(schedule.remaining(now: 5) == 0)
  }

  @Test("unplayed counts only audio, never a late chunk's lead of silence")
  func unplayed() {
    var schedule = PCMSchedule(sampleRate: 1_000)
    #expect(schedule.unplayed(now: 0) == 0)
    _ = schedule.place(frames: 1_000, now: 0)
    // Before the clock reaches the first chunk: all of it, but not the lead.
    #expect(near(schedule.unplayed(now: 0), 1))
    _ = schedule.place(frames: 500, now: 2)
    // Inside the late chunk's lead: the timeline has lead + 0.5 s left, the clip 0.5 s.
    #expect(near(schedule.remaining(now: 2), PCMSchedule.lead + 0.5))
    #expect(near(schedule.unplayed(now: 2), 0.5))
    #expect(near(schedule.unplayed(now: 2 + PCMSchedule.lead + 0.25), 0.25))
    #expect(schedule.unplayed(now: 5) == 0)
  }

  @Test("at a faster rate the lead stretches in media time, so the real headroom stays the same")
  func rate() {
    var schedule = PCMSchedule(sampleRate: 1_000, rate: 2)
    #expect(near(schedule.place(frames: 500, now: 0), PCMSchedule.lead * 2))
    _ = schedule.place(frames: 100, now: 0)
    #expect(near(schedule.place(frames: 100, now: 5), 5 + PCMSchedule.lead * 2))
  }
}
