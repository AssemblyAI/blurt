/// Limits imposed by the Sync STT model behind AssemblyAI's dictation API
/// (the dictation service forwards audio to Sync unchanged, so its caps apply
/// end to end). `DictationSession` auto-releases a held hotkey just before the
/// cap so a long press never records audio the endpoint would reject.
public enum SyncSTTLimits {
  /// Sample rate of the 16 kHz / mono / 16-bit PCM geometry the API
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

  /// Channels in that geometry. Mono, and the capture side has to agree: every
  /// byte-count-to-duration conversion here assumes one channel, so a stereo
  /// recorder would report half the duration it captured.
  static let channelCount = 1

  /// Bit depth of that geometry, derived from `bytesPerSample` rather than
  /// restated. `CaptureSessionRecorder.audioSettings` asks for these three
  /// values instead of spelling 16 and 1 as literals: capture geometry and the
  /// byte math above are one contract, and they used to be two unlinked
  /// definitions with nothing failing if they drifted (`MicCaptureFormatTests`
  /// pins the link).
  static let bitDepth = bytesPerSample * 8

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
    // Convert before dividing: `byteCount / bytesPerSample` in integer arithmetic
    // truncates a trailing partial sample. That can't happen for well-formed S16LE
    // (byte counts are always even), and the error bound is one sample — 0.0625 ms
    // at 16 kHz — but there's no reason for the expression to be wrong for an odd
    // count it might one day be handed.
    return Int((Double(byteCount) / Double(bytesPerSample) / Double(rate)) * 1000)
  }

  /// Safety margin subtracted from the cap for the auto-release timeout, so the
  /// session stops recording before it hits the hard limit.
  public static let autoReleaseMargin: Double = 5

  /// When a held hotkey should auto-release: `maxAudioSeconds - autoReleaseMargin`.
  public static let autoReleaseSeconds = maxAudioSeconds - autoReleaseMargin
}
