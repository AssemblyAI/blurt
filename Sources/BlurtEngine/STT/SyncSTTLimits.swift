/// Limits imposed by AssemblyAI's Sync STT API. `DictationSession` auto-releases
/// a held hotkey just before the cap so a long press never records audio the
/// endpoint would reject.
public enum SyncSTTLimits {
  /// Sample rate of the 16 kHz / mono / 16-bit PCM geometry the Sync API
  /// expects. The single definition shared by `MicCapture` (which records at
  /// this rate) and `DictationSession` (which declares it on the request), so
  /// the recorded and declared rates can't drift apart.
  public static let sampleRate = 16_000

  /// Maximum audio duration the Sync model accepts per request (seconds).
  public static let maxAudioSeconds: Double = 120

  /// Minimum audio duration the Sync model accepts (seconds). The endpoint
  /// rejects anything shorter with a 400, so a recording below this — an
  /// accidental ultra-brief tap — is dropped as a silent no-op rather than sent.
  /// Set a hair above the model's documented ~80 ms floor for margin.
  public static let minAudioSeconds: Double = 0.1

  /// The fewest samples worth sending; a buffer shorter than this is below
  /// `minAudioSeconds` and would only earn a 400. A stored constant (not a
  /// function taking a rate) because the pipeline records at exactly
  /// `sampleRate` — a parameter would just re-ask a question this type already
  /// answers, and invite a floor inconsistent with what's actually recorded.
  /// Internal: the pipeline's floor is `minPCMBytes` (the byte form of this).
  static let minSamples = Int(minAudioSeconds * Double(sampleRate))

  /// Bytes per sample of the 16-bit PCM geometry — the factor between a byte
  /// count of captured audio and its sample count. Internal: hosts size canned
  /// audio with `minPCMBytes`; only the capture/upload code needs the factor.
  static let bytesPerSample = 2

  /// The fewest PCM bytes worth sending: `minSamples` expressed in the raw
  /// S16LE encoding the pipeline captures and uploads — the floor
  /// `DictationSession` applies to the blob `MicCaptureProtocol.stop()` returns.
  public static let minPCMBytes = minSamples * bytesPerSample

  /// Milliseconds of audio a raw S16LE byte count represents at `rate`. Both the
  /// capture side (`MicCapture.stop`) and the upload side
  /// (`AssemblyAITranscriber.transcribe`) log the clip's duration, and those logs
  /// are the documented way to diagnose pipeline latency — deriving it here, from
  /// the two facts this type already owns, keeps them from disagreeing if the
  /// geometry ever changes. Internal for the same reason as `bytesPerSample`:
  /// only the capture/upload code needs it.
  static func durationMs(ofPCMBytes byteCount: Int, rate: Int = sampleRate) -> Int {
    guard rate > 0 else { return 0 }
    return Int((Double(byteCount / bytesPerSample) / Double(rate)) * 1000)
  }

  /// Safety margin subtracted from the cap for the auto-release timeout, so the
  /// session stops recording before it hits the hard limit.
  public static let autoReleaseMargin: Double = 5

  /// When a held hotkey should auto-release: `maxAudioSeconds - autoReleaseMargin`.
  public static let autoReleaseSeconds = maxAudioSeconds - autoReleaseMargin
}
