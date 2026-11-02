import Testing

@testable import BlurtEngine

/// When a recording ends for want of speech.
@Suite("Recording quiet stop")
struct RecordingQuietStopTests {
  private let start = ContinuousClock.now

  @Test("stops only once nothing has been heard for the whole gap")
  func stopsAfterTheGap() {
    let stop = RecordingQuietStop(now: start)
    #expect(!stop.isOver(now: start + RecordingQuietStop.after - .seconds(1)))
    #expect(stop.isOver(now: start + RecordingQuietStop.after))
  }

  @Test("speech restarts the clock")
  func speechResets() {
    var stop = RecordingQuietStop(now: start)
    stop.heard(at: start + .seconds(600))
    #expect(!stop.isOver(now: start + RecordingQuietStop.after))
    #expect(stop.isOver(now: start + .seconds(600) + RecordingQuietStop.after))
  }
}
