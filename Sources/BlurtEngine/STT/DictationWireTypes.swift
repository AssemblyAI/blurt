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
// deliberately bogus one does. The reference's "unknown fields are forwarded to
// the transcription engine as-is" describes the unversioned `/transcribe`, not
// `/v1/transcribe/live` — so a field name here is either one the route knows or
// a request that never transcribes. Guess nothing; measure it.
extension AssemblyAITranscriber {
  struct DictationConfig: Encodable {
    let sampleRate: Int
    let channels: Int
    /// The contextual prompt: the text that preceded this utterance, oldest
    /// first — the user's recent dictations, then the text before the cursor.
    /// Steers *transcription* (continuity, spelling, mid-sentence continuation);
    /// the cleanup rewrite is `rewrite`'s job. A **string**, and only ever a
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
    /// What to ask of the server-side cleanup rewrite — including asking for
    /// none. Three states, because the route has three; see `Rewrite`.
    let rewrite: Rewrite
    enum CodingKeys: String, CodingKey {
      case sampleRate = "sample_rate"
      case channels
      case sttPrompt = "stt_prompt"
      case keytermsPrompt = "keyterms_prompt"
      case llmInstruction = "llm_instruction"
      case llm
    }

    /// Hand-written for the three things synthesis can't express: an empty
    /// `stt_prompt` or `keyterms_prompt` must be *absent*, not `""`/`[]`,
    /// and a non-optional string or array always encodes; `rewrite`'s three
    /// states map to two different keys, one of which has to be an explicit
    /// `null`. A property
    /// added above and forgotten here never reaches the wire — which is what the
    /// config assertions in the tests catch.
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
      switch rewrite {
      case .instructed(let instruction):
        try container.encode(instruction, forKey: .llmInstruction)
      case .serviceDefault:
        break
      case .disabled:
        // `encodeNil`, not omission: see `Rewrite.disabled`. This is the one
        // key in the config that has to be present *and* null.
        try container.encodeNil(forKey: .llm)
      }
    }
  }

  /// What the request asks of the dictation API's server-side rewrite.
  ///
  /// Three cases because the route answers three ways, and the mapping is not
  /// the one an omit-if-nil optional would produce. Measured against
  /// `/v1/transcribe/live` on 2026-09-10, same clip each time:
  ///
  /// | config carries              | `llm_response`                  |
  /// | --------------------------- | ------------------------------- |
  /// | `llm_instruction: "…"`      | our instruction applied         |
  /// | neither key                 | the service's **default** cleanup |
  /// | `llm: null`                 | `null` — no rewrite, no error   |
  ///
  /// The middle row is why this is an enum and not `String?`. "No instruction"
  /// and "no rewrite" are different requests: leaving the keys off does not turn
  /// the rewrite off, it selects the service's own wording. An explicit null
  /// `llm` is the only off switch the route has — `llm: {}`,
  /// `llm: {"enabled": false}` and `llm_instruction: null` all run the default
  /// cleanup, and invented spellings (`llm_enabled`, `disable_llm`) are rejected
  /// outright as unknown keys.
  ///
  /// That distinction is load-bearing for the **enhanced transcripts** setting:
  /// with it off, a config that merely omitted the instruction would come back
  /// with a rewritten transcript anyway, and `transcribe` prefers `llm_response`
  /// whenever it is non-nil — so the user would get cleanup they had switched
  /// off, silently and at no error. `.disabled` is what makes the switch a
  /// switch.
  enum Rewrite: Equatable {
    /// Apply this instruction (`CleanupInstruction.sendable`, style profile and
    /// all) instead of the service's default wording.
    case instructed(String)
    /// Rewrite with the service's own default cleanup instruction — what an
    /// over-cap instruction degrades to, rather than failing the request.
    case serviceDefault
    /// Don't rewrite at all: paste the verbatim transcript as spoken.
    case disabled
  }

  struct DictationResponse: Decodable {
    /// The verbatim transcript — always present, never altered by the LLM.
    let text: String
    /// The rewritten transcript, or nil when the rewrite failed or was not asked
    /// for (`Rewrite.disabled`).
    let llmResponse: String?
    /// `"timeout"` or `"error"` when a requested rewrite failed. Stays nil for a
    /// declined rewrite, so a null `llm_response` alone does not mean failure.
    let llmError: String?
    enum CodingKeys: String, CodingKey {
      case text
      case llmResponse = "llm_response"
      case llmError = "llm_error"
    }
  }

  /// A dictation API failure body. The reference documents exactly two shapes:
  /// `{error_code, message}` for the request/audio/server errors (400, 413, 415,
  /// 500, 503, 504) and `{detail}` for auth and rate limiting — so read
  /// `message`, then `detail`. A non-string `detail` (a FastAPI-style validation
  /// array) is ignored and the caller falls back to the raw body.
  ///
  /// `detail` is the arm that carries config-validation failures, which is what
  /// a wrong field name produces: `invalid config part: <key>: Extra inputs are
  /// not permitted`. Worth keeping readable — it is the difference between a
  /// diagnosable typo and "AssemblyAI error 400".
  struct ErrorResponse: Decodable {
    let message: String?

    enum CodingKeys: String, CodingKey {
      case message, detail
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      // `try? decode` already yields `String?` for a key that is missing, null,
      // or the wrong type — `decodeIfPresent` would return `String??` here and
      // need flattening back down.
      func string(_ key: CodingKeys) -> String? {
        try? container.decode(String.self, forKey: key)
      }
      message = string(.message) ?? string(.detail)
    }
  }
}
