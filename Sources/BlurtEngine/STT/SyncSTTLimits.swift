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

  /// The fewest samples worth sending at `sampleRate`; a buffer shorter than
  /// this is below `minAudioSeconds` and would only earn a 400.
  public static func minSamples(sampleRate: Int) -> Int {
    Int(minAudioSeconds * Double(sampleRate))
  }

  /// Safety margin subtracted from the cap for the auto-release timeout, so the
  /// session stops recording before it hits the hard limit.
  public static let autoReleaseMargin: Double = 5

  /// When a held hotkey should auto-release: `maxAudioSeconds - autoReleaseMargin`.
  public static let autoReleaseSeconds = maxAudioSeconds - autoReleaseMargin
}
