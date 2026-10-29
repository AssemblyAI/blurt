/// Limits imposed by the Sync STT model behind AssemblyAI's dictation API
/// (the dictation service forwards audio to Sync unchanged, so its caps apply
/// end to end). `DictationSession` auto-releases a held hotkey just before the
/// recording cap so a long press never records audio the API would reject.
///
/// Two routes, two caps. The **streaming** route every dictation starts on,
/// `/v1/transcribe/live`, accepts at most 120 s (server-side since
/// 2026-10-14); the **buffered** route, `/v1/transcribe`, accepts 20 minutes
/// and 256 MB. The recording cap below is the buffered route's, and a
/// recording that outlives the streaming route's is finished and sent there
/// whole — `AssemblyAITranscriber+LiveCapFallback.swift`. The 120 s figure has
/// no constant: nothing on the client acts on it, the route enforces it with a
/// `413`, and that response is the trigger.
public enum SyncSTTLimits {
  /// Sample rate of the 16 kHz / mono / 16-bit PCM geometry the API
  /// expects. The single definition shared by `MicCapture` (which records at
  /// this rate) and `DictationSession` (which declares it on the request), so
  /// the recorded and declared rates can't drift apart.
  public static let sampleRate = 16_000

  /// Maximum recording length (seconds): 20 minutes, the buffered route's
  /// documented cap. Raised from 120 s in #251. Only the first 120 s of it fit
  /// the streaming route; a longer recording is refused there and sent whole to
  /// `/v1/transcribe`, which is why a recording past two minutes is held in
  /// memory (`maxBufferedAudioBytes`) until it is sent — ~38 MB at this cap.
  /// The alternative to that copy is putting this back to 120, so a held key
  /// auto-releases just inside the streaming route's cap.
  public static let maxAudioSeconds: Double = 1200

  /// The most audio the over-cap fallback's copy may hold: the buffered
  /// route's documented 256 MB part limit, read as 10⁶-byte megabytes — the
  /// conservative reading of an unstated unit, as `CleanupInstruction`'s byte
  /// count is for its cap. A guard, not a working limit: the 20-minute recording
  /// cap is ~38 MB at this geometry, so it trips only if the geometry changes.
  /// Past it the copy is dropped at once and the fallback fails cleanly with
  /// `AssemblyAIError.recordingTooLarge` rather than sending a truncated
  /// recording.
  static let maxBufferedAudioBytes = 256_000_000

  /// Minimum audio duration worth sending (seconds). Not a rejection
  /// threshold: measured against `/v1/transcribe/live` (2026-09-09) the route
  /// answers 20/50/80 ms clips with 200 and an empty `text`, so a recording
  /// below this — an accidental ultra-brief tap — is dropped as a silent no-op
  /// to avoid paying for a request that transcribes nothing, not to avoid an
  /// error. Set a hair above the model's documented ~80 ms floor for margin,
  /// which is also where words first appear in the sweep.
  public static let minAudioSeconds: Double = 0.1

  /// The sample form of `minAudioSeconds` — see there for what the route
  /// actually does with a shorter clip. A stored constant (not a
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
