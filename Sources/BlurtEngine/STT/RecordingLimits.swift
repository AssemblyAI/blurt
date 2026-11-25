/// How Blurt records a dictation: the capture geometry, the longest a held key
/// records before it auto-releases, and the shortest tap worth sending.
///
/// These are the engine's own policy, and they name no provider. What the
/// speech API accepts is the provider SDK's to state (the AssemblyAI SDK's
/// `DictationLimits`: the route's sample rate, its 20-minute cap and the clip
/// length below which it transcribes nothing), and `RecordingLimitsTests` pins
/// that every number here sits inside those. A provider whose limits differ is
/// a change to that test's expectations, not a hidden mismatch.
public enum RecordingLimits {
  /// Sample rate of the 16 kHz / mono / 16-bit PCM geometry Blurt records
  /// and sends. The single definition shared by `MicCapture` (which records at
  /// this rate) and `DictationSession` (which declares it on the request), so
  /// the recorded and declared rates can't drift apart.
  public static let sampleRate = 16_000

  /// Maximum recording length (seconds): 20 minutes, as long as the provider
  /// accepts (raised from 120 s in #251). How the provider carries a recording
  /// that long — on AssemblyAI, a recording past the streaming route's 120 s is
  /// held in memory and sent whole to the buffered route, ~38 MB at this cap —
  /// is the SDK's (`DictationClient+LiveCapFallback.swift`).
  /// The alternative to that copy is putting this back to 120, so a held key
  /// auto-releases just inside the streaming route's cap.
  public static let maxAudioSeconds: Double = 1_200

  /// Minimum audio duration worth sending (seconds). A recording below this —
  /// an accidental ultra-brief tap — is dropped as a silent no-op rather than
  /// paying for a request that transcribes nothing: the provider answers such a
  /// clip with an empty transcript, not an error. Set a hair above the floor
  /// the provider states, for margin.
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

  /// Safety margin subtracted from the cap for the auto-release timeout, so the
  /// session stops recording before it hits the hard limit.
  public static let autoReleaseMargin: Double = 5

  /// When a held hotkey should auto-release: `maxAudioSeconds - autoReleaseMargin`.
  public static let autoReleaseSeconds = maxAudioSeconds - autoReleaseMargin

  /// Milliseconds of audio a raw S16LE byte count represents at `sampleRate`,
  /// for the capture side's latency line (`MicCapture.stop`), derived from the
  /// two facts this type already owns. The upload side's line is computed by
  /// the AssemblyAI SDK's `DictationClient` from the rate it declares on the
  /// request — the SDK can't import the engine — so the two are separate
  /// arithmetic over the same geometry, each pinned by its own tests.
  static func durationMs(ofPCMBytes byteCount: Int) -> Int {
    // Convert before dividing: `byteCount / bytesPerSample` in integer arithmetic
    // truncates a trailing partial sample. That can't happen for well-formed S16LE
    // (byte counts are always even), and the error bound is one sample — 0.0625 ms
    // at 16 kHz — but there's no reason for the expression to be wrong for an odd
    // count it might one day be handed.
    Int((Double(byteCount) / Double(bytesPerSample) / Double(sampleRate)) * 1_000)
  }
}
