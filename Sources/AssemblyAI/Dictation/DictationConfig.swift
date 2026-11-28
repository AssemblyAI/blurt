public struct DictationConfig: Encodable, Sendable {
  enum CodingKeys: String, CodingKey {
    case sampleRate = "sample_rate"
    case channels
    case sttPrompt = "stt_prompt"
    case keytermsPrompt = "keyterms_prompt"
    case llmInstruction = "llm_instruction"
    case rewriteMode = "rewrite_mode"
  }

  public let sampleRate: Int
  public let channels: Int
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
  public let sttPrompt: String
  /// Keyterms prompting: the user's key terms as a flat array of strings,
  /// biasing recognition toward those exact spellings. A sibling of
  /// `stt_prompt`, not an alternative — the API takes both, for
  /// different jobs (prior text versus a vocabulary list) — fitted by
  /// `KeyTerms` to its own 8000-byte cap, which is a different number
  /// from the 4096 scalars on the prompt. Empty asks for no boosting, and
  /// `encode(to:)` then drops the key rather than sending `[]`.
  ///
  /// **`keyterms_prompt`, and only ever one name for it.** The route accepts
  /// `keyterms` and `word_boost` as legacy aliases, and rejects any request
  /// carrying two of the three: `400 provide only one of keyterms_prompt,
  /// keyterms, or word_boost` (measured, 2026-09-10). So this is a swap, never
  /// an addition — a compatibility shim that sent both names would 400 every
  /// dictation.
  public let keytermsPrompt: [String]
  /// The cleanup instruction the server-side rewrite should apply
  /// (`CleanupInstruction.sendable(appending:)`, style profile and all), or nil to leave
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
  /// (`AssemblyAITranscriber.transcript(from:enhanced:instruction:)`, in
  /// BlurtAssemblyAI).
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
  /// choice unreachable — read `transcript(from:enhanced:)` first.
  public let llmInstruction: String?
  /// Which model the cleanup rewrite runs on, or nil to omit the key and leave
  /// the route on its default. A top-level sibling of `llm_instruction`, which
  /// is where the rest of the rewrite request already lives.
  public let rewriteMode: DictationRewriteMode?

  public init(
    sampleRate: Int,
    channels: Int,
    sttPrompt: String,
    keytermsPrompt: [String],
    llmInstruction: String?,
    rewriteMode: DictationRewriteMode? = nil
  ) {
    self.sampleRate = sampleRate
    self.channels = channels
    self.sttPrompt = sttPrompt
    self.keytermsPrompt = keytermsPrompt
    self.llmInstruction = llmInstruction
    self.rewriteMode = rewriteMode
  }

  /// Hand-written for the one thing synthesis can't express: an empty
  /// `stt_prompt` or `keyterms_prompt` must be *absent*, not `""`/`[]`, and a
  /// non-optional string or array always encodes. (`llmInstruction` would
  /// omit-if-nil on its own; it is spelled out here so the whole wire shape
  /// reads in one place.) A property added above and forgotten here never
  /// reaches the wire — which is what the config assertions in the tests
  /// catch.
  public func encode(to encoder: any Encoder) throws {
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
    try container.encodeIfPresent(rewriteMode, forKey: .rewriteMode)
  }
}
