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
}
