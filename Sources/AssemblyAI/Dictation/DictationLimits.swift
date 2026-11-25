/// What the dictation API accepts in a recording, for a caller sizing its
/// own: the audio geometry it expects, the longest recording it takes, and the
/// shortest it transcribes anything from.
///
/// Two routes, two caps. The **streaming** route every dictation starts on,
/// `/v1/transcribe/live`, accepts at most 120 s (server-side since
/// 2026-10-14); the **buffered** route, `/v1/transcribe`, accepts 20 minutes
/// and 256 MB. `DictationClient` sends a recording that outlives the streaming
/// route's cap to the buffered route whole
/// (`DictationClient+LiveCapFallback.swift`), so `maxAudioSeconds` is the
/// buffered route's. The 120 s figure has no constant: nothing on the client
/// acts on it, the route enforces it with a `413`, and that response is the
/// trigger.
public enum DictationLimits {
  /// The sample rate of the 16 kHz / mono / 16-bit PCM geometry the route's
  /// model expects (the dictation service forwards audio to it unchanged).
  public static let sampleRate = 16_000

  /// The longest recording the API accepts (seconds): the buffered route's
  /// documented 20 minutes.
  public static let maxAudioSeconds: Double = 1_200

  /// The model's documented floor (seconds), ~80 ms. Not a rejection threshold:
  /// measured against `/v1/transcribe/live` (2026-09-09), the route answers 20,
  /// 50 and 80 ms clips with a 200 and an empty `text`, so a shorter recording
  /// is a request billed for transcribing nothing. 80 ms is also where words
  /// first appeared in that sweep. A caller drops such a clip itself, through
  /// `DictationClient`'s `minimumAudioBytes`.
  public static let minAudioSeconds = 0.08
}
