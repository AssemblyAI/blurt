import Foundation
import Testing

@testable import BlurtEngine

/// Hits a real `AVCaptureSession` and the system mic, so it rides the
/// `requiresLiveAudio` gate (set BLURT_LIVE_AUDIO_TESTS=1 in the scheme to
/// enable). `.timeLimit` fails fast if the capture hangs instead of stalling the
/// whole run.
@Suite("MicCapture.levels (live)")
struct MicCaptureLevelsTests {
  @Test(
    "levels yield during capture",
    ConditionTrait.requiresLiveAudio,
    .tags(.liveAudio),
    .timeLimit(.minutes(1)))
  func levelsYieldDuringCapture() async throws {
    // See `LiveAudioDevice`: the suites that open the mic take turns, so the one
    // asserting on the device's own "is anyone capturing" bit isn't reading ours.
    await LiveAudioDevice.acquire()
    defer { LiveAudioDevice.release() }

    let mic = MicCapture(deviceSelection: { .systemDefault })

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
