import Testing

@testable import BlurtEngine

/// `SyncSTTLimits` is a tiny constants table, but `MicCapture` (buffer sizing)
/// and `DictationSession` (auto-release timeout) both depend on its arithmetic
/// holding — the auto-release must fire *before* the hard audio cap, never at or
/// after it. These tests pin the invariant so a future edit to one constant
/// can't silently push the auto-release past the limit it's meant to beat.
@Suite("SyncSTTLimits")
struct SyncSTTLimitsTests {
  @Test("auto-release is the audio cap minus the safety margin")
  func autoReleaseDerivation() {
    #expect(SyncSTTLimits.autoReleaseSeconds == SyncSTTLimits.maxAudioSeconds - SyncSTTLimits.autoReleaseMargin)
  }

  @Test("auto-release fires strictly before the hard audio cap")
  func autoReleaseBeatsTheCap() {
    // The whole point of the margin: stop recording before the endpoint would
    // reject the clip. A non-positive margin would defeat that.
    #expect(SyncSTTLimits.autoReleaseMargin > 0)
    #expect(SyncSTTLimits.autoReleaseSeconds < SyncSTTLimits.maxAudioSeconds)
  }

  @Test(
    "limits are positive durations",
    arguments: [
      ("maxAudioSeconds", SyncSTTLimits.maxAudioSeconds),
      ("autoReleaseSeconds", SyncSTTLimits.autoReleaseSeconds),
      ("autoReleaseMargin", SyncSTTLimits.autoReleaseMargin),
    ])
  func limitIsPositive(_ limit: (name: String, value: Double)) {
    #expect(limit.value > 0, "\(limit.name) must be a positive duration")
  }
}
