import Testing

@testable import AssemblyAI
@testable import BlurtAssemblyAI
@testable import BlurtEngine

/// `RecordingLimits` is a tiny constants table, but `MicCapture` (buffer sizing)
/// and `DictationSession` (auto-release timeout) both depend on its arithmetic
/// holding — the auto-release must fire *before* the hard audio cap, never at or
/// after it. These tests pin the invariant so a future edit to one constant
/// can't silently push the auto-release past the limit it's meant to beat.
@Suite("RecordingLimits")
struct RecordingLimitsTests {
  @Test("auto-release is the audio cap minus the safety margin")
  func autoReleaseDerivation() {
    #expect(RecordingLimits.autoReleaseSeconds == RecordingLimits.maxAudioSeconds - RecordingLimits.autoReleaseMargin)
  }

  @Test("auto-release fires strictly before the hard audio cap")
  func autoReleaseBeatsTheCap() {
    // The whole point of the margin: stop recording before the endpoint would
    // reject the clip. A non-positive margin would defeat that.
    #expect(RecordingLimits.autoReleaseMargin > 0)
    #expect(RecordingLimits.autoReleaseSeconds < RecordingLimits.maxAudioSeconds)
  }

  @Test("minSamples is the minimum duration expressed at the capture sample rate")
  func minSamplesDerivation() {
    // If this product drifted from the duration floor, ultra-brief taps would
    // reach the API and earn a 400 (or real clips would silently be dropped).
    #expect(RecordingLimits.minSamples == Int(RecordingLimits.minAudioSeconds * Double(RecordingLimits.sampleRate)))
    #expect(RecordingLimits.minSamples == 1_600)
  }

  @Test("minPCMBytes is minSamples in the captured 16-bit encoding")
  func minPCMBytesDerivation() {
    // DictationSession's too-short-clip guard measures the raw S16LE blob; the
    // byte floor must stay exactly the sample floor times the sample width.
    #expect(RecordingLimits.bytesPerSample == 2)
    #expect(RecordingLimits.minPCMBytes == RecordingLimits.minSamples * RecordingLimits.bytesPerSample)
    #expect(RecordingLimits.minPCMBytes == 3_200)
  }

  @Test("durationMs converts a raw S16LE byte count to milliseconds")
  func durationMsDerivation() {
    // The capture log (MicCapture.stop) reports a clip's duration through this,
    // and that log is the documented way to diagnose pipeline latency — so pin
    // the arithmetic rather than only exercising it incidentally.
    #expect(RecordingLimits.durationMs(ofPCMBytes: RecordingLimits.minPCMBytes) == 100)
    #expect(RecordingLimits.durationMs(ofPCMBytes: 32_000) == 1_000)
    #expect(RecordingLimits.durationMs(ofPCMBytes: 0) == 0)
  }

  @Test("the capture geometry is the dictation API's 16 kHz")
  func sampleRatePinned() {
    // Shared by MicCapture (recording) and the request's declared rate — a
    // change here alters both, so pin the agreed value.
    #expect(RecordingLimits.sampleRate == 16_000)
  }

  @Test("the audio cap is the dictation API's 20 minutes, auto-released 5 s early")
  func audioCapPinned() {
    // What a user feels: a held trigger stops recording at 19 min 55 s. Pinned
    // so moving either number is a deliberate change, not a side effect.
    #expect(RecordingLimits.maxAudioSeconds == 1_200)
    #expect(RecordingLimits.autoReleaseSeconds == 1_195)
  }

  @Test("a whole recording at the cap fits the fallback's copy, with room to spare")
  func fullRecordingFitsTheBufferedCap() {
    // The guard is a guard, not a working limit: a 20-minute recording at the
    // capture geometry (~38 MB) must never trip it, or every long dictation that
    // reached the buffered route would fail at release.
    let fullRecording =
      Int(RecordingLimits.maxAudioSeconds) * RecordingLimits.sampleRate * RecordingLimits.bytesPerSample
      * RecordingLimits.channelCount
    #expect(fullRecording < DictationClient.maxBufferedAudioBytes)
    // And it is the documented 256 MB, read in its conservative unit.
    #expect(DictationClient.maxBufferedAudioBytes == 256_000_000)
  }

  @Test("the minimum audio floor sits strictly inside the accepted range")
  func minFloorInsideRange() {
    #expect(RecordingLimits.minAudioSeconds > 0)
    #expect(RecordingLimits.minAudioSeconds < RecordingLimits.maxAudioSeconds)
  }

  @Test(
    "limits are positive durations",
    arguments: [
      ("maxAudioSeconds", RecordingLimits.maxAudioSeconds),
      ("autoReleaseSeconds", RecordingLimits.autoReleaseSeconds),
      ("autoReleaseMargin", RecordingLimits.autoReleaseMargin),
    ])
  func limitIsPositive(_ limit: (name: String, value: Double)) {
    #expect(limit.value > 0, "\(limit.name) must be a positive duration")
  }

  @Test("the engine's recording policy fits what the dictation API accepts")
  func policyFitsTheProvider() {
    // The engine names no provider, so nothing else links its numbers to the
    // API's: the recorded rate is the one the route expects, a held key stops
    // inside the API's cap, and a tap below the floor the API transcribes
    // nothing under is never sent.
    #expect(RecordingLimits.sampleRate == DictationLimits.sampleRate)
    #expect(RecordingLimits.maxAudioSeconds <= DictationLimits.maxAudioSeconds)
    #expect(RecordingLimits.minAudioSeconds >= DictationLimits.minAudioSeconds)
    #expect(AssemblyAITranscriber.fitsRecordingLimits)
  }

  @Test("the dictation API's limits are the documented and measured ones")
  func providerLimitsPinned() {
    // 16 kHz mono 16-bit, the buffered route's 20 minutes, and the ~80 ms floor
    // below which the route answers 200 with an empty transcript (2026-09-09).
    #expect(DictationLimits.sampleRate == 16_000)
    #expect(DictationLimits.maxAudioSeconds == 1_200)
    #expect(DictationLimits.minAudioSeconds == 0.08)
  }
}
