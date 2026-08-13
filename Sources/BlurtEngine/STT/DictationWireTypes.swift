// The dictation API's JSON contract: the `config` part `AssemblyAITranscriber`
// encodes, and the success/error bodies it decodes. Split from
// `AssemblyAITranscriber.swift` to stay within the lint file-length budget —
// that file is the transport (multipart framing, timeouts, metrics), this one is
// the wire shape. Nested in the transcriber, and internal rather than private,
// only because Swift's `private` is file-scoped and cannot cross the split.
extension AssemblyAITranscriber {
  struct DictationConfig: Encodable {
    let sampleRate: Int
    let channels: Int
    /// The dialogue that preceded this utterance, oldest turn first: the user's
    /// recent dictations, then the text before the cursor. Steers
    /// *transcription* (continuity, spelling, mid-sentence continuation); the
    /// cleanup rewrite is the `llm` block's job. Always encoded as a **JSON array
    /// of strings**, even for a single turn — the API also accepts a bare string
    /// there, and collapsing to one would make a one-turn request a different
    /// shape from every other. Empty means no prior dialogue, and `encode(to:)`
    /// then drops the key rather than sending `[]`. Assembled by
    /// `ConversationContext`, which is also where the reason there is no
    /// `prompt` field lives.
    let conversationContext: [String]
    /// Word boosting: the user's key terms as a flat array of strings, biasing
    /// recognition toward those exact spellings. A sibling of
    /// `conversation_context`, not an alternative — the API takes both, for
    /// different jobs (prior dialogue versus a vocabulary list) — fitted by
    /// `KeytermsBoost` to its own 2048-character cap, which is a different number
    /// from the 4096 on the context. Empty asks for no boosting, and
    /// `encode(to:)` then drops the key rather than sending `[]`.
    let wordBoost: [String]
    /// The rewrite request, present only while enhanced transcripts are
    /// enabled (nil — the synthesized `encode` omits it — asks for no rewrite,
    /// so the response's `llm_response` is null and the verbatim `text` is
    /// used). It carries our own `instruction` (`CleanupInstruction`); an empty
    /// object would instead select the service's default cleanup instruction.
    let llm: LLMRewrite?
    enum CodingKeys: String, CodingKey {
      case sampleRate = "sample_rate"
      case channels
      case conversationContext = "conversation_context"
      case wordBoost = "word_boost"
      case llm
    }

    /// Hand-written for the fields synthesis can't express: an empty
    /// `conversation_context` or `word_boost` must be *absent*, not `[]`, and a
    /// non-optional array always encodes. `llm` keeps the `encodeIfPresent`
    /// behavior it had. A property added above and forgotten here never reaches
    /// the wire — which is what the config assertions in the tests catch.
    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(sampleRate, forKey: .sampleRate)
      try container.encode(channels, forKey: .channels)
      if !conversationContext.isEmpty {
        try container.encode(conversationContext, forKey: .conversationContext)
      }
      if !wordBoost.isEmpty {
        try container.encode(wordBoost, forKey: .wordBoost)
      }
      try container.encodeIfPresent(llm, forKey: .llm)
    }
  }

  /// The cleanup-rewrite request. Its one field is the instruction the service
  /// applies to the verbatim transcript — see `CleanupInstruction` for where the
  /// wording came from, what the eval behind it does and doesn't establish, and
  /// why its length is load-bearing. Dropping the field reverts to the service's
  /// own default cleanup instruction, which is what shipped before.
  struct LLMRewrite: Encodable {
    /// Optional so an over-cap instruction encodes as `{}` rather than as a request
    /// the API will reject outright — see `CleanupInstruction.sendable`. The
    /// synthesized `encode` uses `encodeIfPresent`, so nil omits the key entirely.
    let instruction: String?
  }

  struct DictationResponse: Decodable {
    /// The verbatim transcript — always present, never altered by the LLM.
    let text: String
    /// The rewritten transcript, or nil when the rewrite failed or timed out.
    let llmResponse: String?
    /// `"timeout"` or `"error"` when a requested rewrite failed.
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
