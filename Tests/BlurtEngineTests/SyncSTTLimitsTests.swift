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

  @Test("minSamples is the minimum duration expressed at the capture sample rate")
  func minSamplesDerivation() {
    // If this product drifted from the duration floor, ultra-brief taps would
    // reach the API and earn a 400 (or real clips would silently be dropped).
    #expect(SyncSTTLimits.minSamples == Int(SyncSTTLimits.minAudioSeconds * Double(SyncSTTLimits.sampleRate)))
    #expect(SyncSTTLimits.minSamples == 1600)
  }

  @Test("minPCMBytes is minSamples in the captured 16-bit encoding")
  func minPCMBytesDerivation() {
    // DictationSession's too-short-clip guard measures the raw S16LE blob; the
    // byte floor must stay exactly the sample floor times the sample width.
    #expect(SyncSTTLimits.bytesPerSample == 2)
    #expect(SyncSTTLimits.minPCMBytes == SyncSTTLimits.minSamples * SyncSTTLimits.bytesPerSample)
    #expect(SyncSTTLimits.minPCMBytes == 3200)
  }

  @Test("the capture geometry is the Sync API's 16 kHz")
  func sampleRatePinned() {
    // Shared by MicCapture (recording) and the request's declared rate — a
    // change here alters both, so pin the agreed value.
    #expect(SyncSTTLimits.sampleRate == 16_000)
  }

  @Test("the minimum audio floor sits strictly inside the accepted range")
  func minFloorInsideRange() {
    #expect(SyncSTTLimits.minAudioSeconds > 0)
    #expect(SyncSTTLimits.minAudioSeconds < SyncSTTLimits.maxAudioSeconds)
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
