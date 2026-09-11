// The dictation API's JSON contract: the `config` part `AssemblyAITranscriber`
// encodes, and the success/error bodies it decodes. Split from
// `AssemblyAITranscriber.swift` to stay within the lint file-length budget —
// that file is the transport (multipart framing, timeouts, metrics), this one is
// the wire shape. Nested in the transcriber, and internal rather than private,
// only because Swift's `private` is file-scoped and cannot cross the split.
//
// Every field name here was swept against the live route on 2026-09-10, because
// the route validates its config **strictly**: an unrecognized key earns
// `400 invalid config part: <key>: Extra inputs are not permitted`, exactly as a
// deliberately bogus one does. The reference says the opposite about this
// endpoint — "Over HTTP, unknown fields are forwarded to the transcription
// engine as-is" — but re-measured 2026-09-11, a config carrying
// `blurt_probe_bogus_key: 1` earns `400 invalid config part:
// blurt_probe_bogus_key: Extra inputs are not permitted`.
//
// **The docs are the source of truth for what to send, and that disagreement
// does not change what this file does**: every key below is one the reference
// documents, so nothing here depends on unknown fields being either forwarded or
// rejected. Keep it that way and the question stays academic.
//
// The corollary is the one that bites. The route *accepts* more names than the
// reference lists — `prompt`, `keyterms`, `word_boost` and `language_code` are
// all live, and the docs call the first three legacy aliases — so a 200 is not
// evidence a field is supported, only that it has not been removed yet. There
// has been a lot of renaming on this route. Treat any name absent from the docs
// as deprecated and don't send it, however well it works today.
extension AssemblyAITranscriber {
  struct DictationConfig: Encodable {
    let sampleRate: Int
    let channels: Int
    /// The contextual prompt: the text that preceded this utterance, oldest
    /// first — the user's recent dictations, then the text before the cursor.
    /// Steers *transcription* (continuity, spelling, mid-sentence continuation);
    /// the cleanup rewrite is `llmInstruction`'s job. A **string**, and only ever a
    /// string: the route rejects an array with
    /// `stt_prompt: Input should be a valid string`. Empty means no prior text,
    /// and `encode(to:)` then drops the key rather than sending `""`. Assembled
    /// by `STTPrompt`, which is also where the 4096-scalar cap and the reason
    /// this replaced `conversation_context` live.
    ///
    /// `prompt` is the same field under its other name — sending both earns
    /// `provide only one of stt_prompt or prompt; they are the same field` — so
    /// never add one alongside this.
    let sttPrompt: String
    /// Keyterms prompting: the user's key terms as a flat array of strings,
    /// biasing recognition toward those exact spellings. A sibling of
    /// `stt_prompt`, not an alternative — the API takes both, for
    /// different jobs (prior text versus a vocabulary list) — fitted by
    /// `KeytermsBoost` to its own 2048-byte cap, which is a different number
    /// from the 4096 scalars on the prompt. Empty asks for no boosting, and
    /// `encode(to:)` then drops the key rather than sending `[]`.
    ///
    /// **`keyterms_prompt`, and only ever one name for it.** The route accepts
    /// `keyterms` and `word_boost` as legacy aliases, and rejects any request
    /// carrying two of the three: `400 provide only one of keyterms_prompt,
    /// keyterms, or word_boost` (measured, 2026-09-10). So this is a swap, never
    /// an addition — a compatibility shim that sent both names would 400 every
    /// dictation.
    let keytermsPrompt: [String]
    /// The cleanup instruction the server-side rewrite should apply
    /// (`CleanupInstruction.sendable`, style profile and all), or nil to leave
    /// the wording to the service. `encode(to:)` then drops the key.
    ///
    /// **Nil is not "no rewrite."** The route rewrites *by default*, which the
    /// reference states outright — "Omitting the field, or setting it to
    /// `null`, keeps the default cleanup task" — and which was measured the
    /// same way on 2026-09-10: a config carrying neither `llm_instruction` nor
    /// `llm` comes back with `llm_response` set to a **default-cleaned**
    /// transcript. Omission selects the service's own wording; it does not
    /// decline.
    ///
    /// **The route documents no way to decline at all**, and the escape it
    /// prescribes is the one Blurt now takes: ignore `llm_response` and use
    /// `text`, which is "always the verbatim transcript". So the config carries
    /// no off switch, and the *response* is where the enhanced-transcripts
    /// setting chooses between the two transcripts
    /// (`AssemblyAITranscriber.transcript(from:)`).
    ///
    /// An explicit null `llm` does suppress the rewrite — measured 2026-09-10 and
    /// re-confirmed 2026-09-11 (200, with `llm_response` and `llm_error` both
    /// null), and the only off switch there is — but it appears **nowhere in the
    /// reference**, and no documented spelling substitutes for it: `llm: {}`,
    /// `llm: {"enabled": false}` and `llm_instruction: null` all run the default
    /// cleanup, while invented names (`llm_enabled`, `disable_llm`) are rejected
    /// as unknown keys.
    ///
    /// That it works is therefore not a reason to send it. **Blurt calls this
    /// API only the way the docs describe it** — an undocumented field carries
    /// no compatibility promise, so a switch built on one is a switch that can
    /// stop being a switch without notice, silently pasting cleaned-up text to
    /// users who turned cleanup off. That is the failure this whole path already
    /// shipped once, by a different route. Blurt sent the null until 2026-09-11.
    /// Adding an `llm` case back would reintroduce it *and* leave the response's
    /// choice unreachable — read `transcript(from:)` first.
    let llmInstruction: String?
    enum CodingKeys: String, CodingKey {
      case sampleRate = "sample_rate"
      case channels
      case sttPrompt = "stt_prompt"
      case keytermsPrompt = "keyterms_prompt"
      case llmInstruction = "llm_instruction"
    }

    /// Hand-written for the one thing synthesis can't express: an empty
    /// `stt_prompt` or `keyterms_prompt` must be *absent*, not `""`/`[]`, and a
    /// non-optional string or array always encodes. (`llmInstruction` would
    /// omit-if-nil on its own; it is spelled out here so the whole wire shape
    /// reads in one place.) A property added above and forgotten here never
    /// reaches the wire — which is what the config assertions in the tests
    /// catch.
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(sampleRate, forKey: .sampleRate)
      try container.encode(channels, forKey: .channels)
      if !sttPrompt.isEmpty {
        try container.encode(sttPrompt, forKey: .sttPrompt)
      }
      if !keytermsPrompt.isEmpty {
        try container.encode(keytermsPrompt, forKey: .keytermsPrompt)
      }
      try container.encodeIfPresent(llmInstruction, forKey: .llmInstruction)
    }
  }

  struct DictationResponse: Decodable {
    /// The verbatim transcript — always present, never altered by the LLM. What
    /// gets pasted with **enhanced transcripts** off, and the fallback when it
    /// is on but the rewrite is unusable.
    let text: String
    /// The rewritten transcript, or nil when the rewrite failed. Every request
    /// asks for one, so — unlike before — nil here means failure rather than
    /// possibly a declined rewrite.
    let llmResponse: String?
    /// `"timeout"` or `"error"` when the rewrite failed, which is the only
    /// reason `llm_response` can be null now that every request asks for one.
    let llmError: String?
    /// The request identifier, which the reference says to "include it when
    /// reporting problems" — so it is logged on every round trip
    /// (`logServerMetrics`). Without it a user's report of a bad dictation
    /// cannot be tied to the request that produced it.
    let sessionId: String?
    /// The service's own duration for the audio it received. Worth having
    /// beside the client's `audioMs`, which is computed from the bytes *sent*:
    /// a disagreement means the upload was truncated, which no other signal
    /// distinguishes from a user who simply stopped talking.
    let audioDurationMs: Double?
    /// Total server-side processing time, and the transcription portion of it.
    /// The pair localizes a slow dictation that the client's `postSpeechMs`
    /// only reports the total of: `request_time_ms` minus `sync_time_ms` is
    /// roughly what the rewrite cost, so a regression can be attributed to the
    /// network, the STT upstream, or the LLM rather than guessed at.
    let requestTimeMs: Double?
    let syncTimeMs: Double?
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
  }

  /// A dictation API failure body. The reference documents exactly two shapes
  /// and says to read both: `{error, error_code}` for most failures (400, 401,
  /// 413, 429, 502, 503, 504) and `{status, title, detail}` for the ones relayed
  /// from the transcription service — an invalid API key (404, *not* 401) and an
  /// unsupported audio format (415). A non-string `detail` (a FastAPI-style
  /// validation array) is ignored and the caller falls back to the raw body.
  ///
  /// **`error` is the field the common failures carry**, and reading it is not
  /// optional dressing: 400 is the config-validation status, so a wrong field
  /// name lands here as
  /// `{"error": "invalid config part: <key>: Extra inputs are not permitted",
  /// "error_code": "bad_request"}`. This type consulted `message` and `detail`
  /// until 2026-09-11, so every one of those fell through to the raw-body arm
  /// and surfaced as JSON.
  ///
  /// **Exactly these two keys, because they are the two the reference
  /// documents.** `message` was the first key read here and is in neither
  /// documented shape; it was dropped rather than kept as a harmless fallback,
  /// under the same rule that took `llm: null` off the request — Blurt calls
  /// this API only the way the docs describe it, on both directions of the
  /// wire. A body carrying some third spelling now reaches the user through the
  /// raw-body arm below, which is the honest outcome: unrecognized, not silently
  /// guessed at.
  struct ErrorResponse: Decodable {
    let message: String?

    enum CodingKeys: String, CodingKey {
      case error, detail
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      // `try? decode` already yields `String?` for a key that is missing, null,
      // or the wrong type — `decodeIfPresent` would return `String??` here and
      // need flattening back down.
      func string(_ key: CodingKeys) -> String? {
        try? container.decode(String.self, forKey: key)
      }
      message = string(.error) ?? string(.detail)
    }
  }
}
