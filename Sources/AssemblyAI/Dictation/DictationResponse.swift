public struct DictationResponse: Decodable, Sendable {
  /// **All optional except `text`, and deliberately so**, even though the
  /// reference marks `session_id` and `audio_duration_ms` required. A
  /// non-optional here turns a field the service stops sending into
  /// `AssemblyAIError.malformedResponse` — a failed dictation, for a
  /// diagnostic nobody was waiting on. `text` is the only field whose absence
  /// means there is nothing to paste.
  enum CodingKeys: String, CodingKey {
    case text
    case llmResponse = "llm_response"
    case llmError = "llm_error"
    case sessionId = "session_id"
    case audioDurationMs = "audio_duration_ms"
    case requestTimeMs = "request_time_ms"
    case syncTimeMs = "sync_time_ms"
  }

  /// The verbatim transcript — always present, never altered by the LLM. What
  /// gets pasted with **enhanced transcripts** off, and the fallback when it
  /// is on but the rewrite is unusable.
  public let text: String
  /// The rewritten transcript, or nil when the rewrite failed. Every request
  /// asks for one, so — unlike before — nil here means failure rather than
  /// possibly a declined rewrite.
  public let llmResponse: String?
  /// `"timeout"` or `"error"` when the rewrite failed, which is the only
  /// reason `llm_response` can be null now that every request asks for one.
  public let llmError: String?
  /// The request identifier, which the reference says to "include it when
  /// reporting problems" — so it is logged on every round trip
  /// (`logServerMetrics`). Without it a user's report of a bad dictation
  /// cannot be tied to the request that produced it.
  public let sessionId: String?
  /// The service's own duration for the audio it received. Worth having
  /// beside the client's `audioMs`, which is computed from the bytes *sent*:
  /// a disagreement means the upload was truncated, which no other signal
  /// distinguishes from a user who simply stopped talking.
  public let audioDurationMs: Double?
  /// Total server-side processing time, and the transcription portion of it.
  /// The pair localizes a slow dictation that the client's `postSpeechMs`
  /// only reports the total of: `request_time_ms` minus `sync_time_ms` is
  /// roughly what the rewrite cost, so a regression can be attributed to the
  /// network, the STT upstream, or the LLM rather than guessed at.
  public let requestTimeMs: Double?
  public let syncTimeMs: Double?
}
