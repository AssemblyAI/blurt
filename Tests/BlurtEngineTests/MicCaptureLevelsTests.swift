import Foundation
import Testing

@testable import BlurtEngine

extension Tag {
  /// Marks tests that drive the real AVAudioEngine and the system mic. They only
  /// run when BLURT_LIVE_AUDIO_TESTS=1; the tag lets a run include/exclude them
  /// as a group (e.g. `--filter-tag liveAudio`).
  @Tag static var liveAudio: Self
}

/// Hits the real AVAudioEngine and the system mic, so it's gated on
/// BLURT_LIVE_AUDIO_TESTS=1 (set it in the scheme to enable). Using
/// `.enabled(if:)` rather than an in-body `guard … else { return }` means a
/// normal run reports this as *skipped* instead of a silent pass — the skip is
/// visible, so no one mistakes "didn't run" for "passed". `.timeLimit` fails fast
/// if the capture hangs instead of stalling the whole run.
@Suite("MicCapture.levels (live)")
struct MicCaptureLevelsTests {
  @Test(
    "levels yield during capture",
    .enabled(
      if: ProcessInfo.processInfo.environment["BLURT_LIVE_AUDIO_TESTS"] == "1",
      "set BLURT_LIVE_AUDIO_TESTS=1 to run (needs a real microphone)"),
    .tags(.liveAudio),
    .timeLimit(.minutes(1)))
  func levelsYieldDuringCapture() async throws {
    let mic = MicCapture()

    let collector = Task { () -> [Float] in
      var collected: [Float] = []
      let deadline = Date().addingTimeInterval(0.7)
      for await level in mic.levels {
        collected.append(level)
        if collected.count >= 3 || Date() > deadline || Task.isCancelled { break }
      }
      return collected
    }

    try await mic.start()
    try await Task.sleep(for: .milliseconds(500))
    _ = try await mic.stop()
    collector.cancel()

    let levels = await collector.value
    #expect(!levels.isEmpty, "expected at least one RMS sample during 500ms of capture")
    #expect(levels.allSatisfy { $0 >= 0 }, "RMS values must be non-negative")
  }
}
