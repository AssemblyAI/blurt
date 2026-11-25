#if os(macOS)
  import CoreAudio
  import Foundation
  import Synchronization
  import Testing

  @testable import BlurtEngine

  /// `Duration.milliseconds` backs the latency lines `MicCapture` logs for the
  /// liveness gap — the field evidence for whether the gate is doing anything —
  /// so a silently wrong conversion would make those logs lie.
  @Suite("Duration.milliseconds")
  struct DurationMillisecondsTests {
    @Test
    func convertsWholeAndFractionalDurations() {
      #expect(Duration.milliseconds(250).milliseconds == 250)
      #expect(Duration.seconds(2).milliseconds == 2_000)
      #expect(Duration.zero.milliseconds == 0)
      // Sub-millisecond durations keep their fraction rather than truncating to 0.
      #expect(Duration.microseconds(500).milliseconds == 0.5)
    }
  }
#endif
