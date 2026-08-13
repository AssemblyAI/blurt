/// Builds the instruction sent to the dictation API as the `prompt`
/// field of the request `config` (see `AssemblyAITranscriber`). The STT model
/// prepends this to its own system prompt.
///
/// **One context signal only: the text immediately before the cursor.** The
/// prompt is back on after being switched off wholesale, but it is deliberately
/// narrower than the version that was switched off: the frontmost app name, the
/// window title, the focused field's label, and the selected text are captured
/// for other purposes (paste spacing, the injector's window identity, the
/// developer-mode log) and **none of them go on the wire**. What this field
/// carries is the prior-chunk continuation and a fixed instruction with no user
/// data in it — nothing about which app is frontmost or what its window is
/// called.
///
/// The user's key terms aren't here either, but for a different reason: they are
/// sent, as their own request field. Word boosting takes a flat list of strings
/// (`config.keyterms_prompt` — see `KeytermsBoost`), which is what the Settings
/// field collects; packing them into this prompt as a `Keywords: a, b, c.` clause
/// was the older, worse shape for the same intent.
///
/// Every built prompt is the prior-chunk block followed by the fixed
/// `baseInstruction` — a plain-text exclusion clause (see below). The prior
/// chunk is *contextual* priming, which the model is mid-trained to use for
/// better recognition accuracy: it continues the sentence the cursor is sitting
/// in, so vocabulary, capitalization, and mid-sentence continuity carry over
/// from what the user already typed.
///
/// On the directives in `baseInstruction`: a "remove filler words"-style
/// *content* reshaping is **not** in the model's trained instruction set, so it
/// is a no-op and is deliberately omitted (see the project memory note). A
/// language directive is likewise omitted — pinning the prompt to English hurt
/// non-English transcription, so language is left to the model's own detection.
/// The negative feature *exclusion* ("without speaker labels, …") is a trained
/// instruction-following type, so it does take effect — the exclusion
/// suppresses the annotation markers the model would otherwise emit (`[Speaker]`,
/// `[door creaks]`, `[laughing]`, …), which in a dictation product would be
/// pasted into the user's text as literal tokens. The list is trimmed to the
/// three annotation types a dictation user could plausibly trigger; the rarer
/// types (unclear-speech, censor, foreign-language, lyrics) are left out to keep
/// the negative clause short, matching the doc's brief negative examples.
///
/// Output follows the trained `{context}\n\n{instruction}` shape: the prior
/// chunk leads as its own paragraph, `baseInstruction` closes. It stays under
/// the API's `characterCap` — `build` clips the prior chunk to whatever the
/// instruction leaves, so the cap holds no matter what a caller passes in.
/// Exercised by `Tests/BlurtEngineTests/TranscriptionPromptTests.swift`.
enum TranscriptionPrompt {
  /// The standing dictation instruction that closes every built prompt. A
  /// negative-exclusion clause (§5/§6) naming the annotation feature types the
  /// model is trained to emit, so it suppresses them. Fixed text: it carries no
  /// user data, which is why it isn't part of what "context" means here. No
  /// language directive: pinning the prompt to English degraded transcription
  /// for non-English speech, so the model is left to detect the spoken language
  /// itself.
  static let baseInstruction =
    "Transcribe without speaker labels, audio event descriptions, or emotion markers."

  /// The label the prior chunk is filed under in the prompt.
  static let priorHeading = "Previous transcript:"

  /// Hard cap the dictation API places on `config.prompt` ("max 4096 chars");
  /// a longer prompt risks failing the whole request, so `build` must never
  /// exceed it. `FocusCapture` already clips the prior chunk far shorter than
  /// this, but the cap is enforced here rather than assumed of the caller —
  /// this is the last place before the wire.
  static let characterCap = 4096

  /// The prompt sent for `context`: the text before the cursor framed as prior
  /// context, closed by `baseInstruction` — or `nil` when there is no such text,
  /// in which case `AssemblyAITranscriber` omits `config.prompt` and the server
  /// applies its own default.
  ///
  /// Only `priorText` is read. The focus fields of `TranscriptionContext` are
  /// captured for the paste path and the developer-mode log and stay on the
  /// machine; adding one of them here is what it would take to send it, and that
  /// is a deliberate decision, not an oversight (see the type's doc comment).
  /// `keyTerms` is absent for the opposite reason — it has its own field on the
  /// request (`KeytermsBoost`).
  ///
  /// Every caller that reports or transmits the prompt goes through here, so the
  /// developer-mode log records exactly what went on the wire.
  static func build(context: TranscriptionContext?) -> String? {
    guard let context, let prior = context.priorText.trimmedNonEmpty() else { return nil }
    // Budget for the prior chunk: the cap less the heading, its newline, the
    // blank-line separator, and the instruction. Clipping keeps the *tail* —
    // the text nearest the cursor is what the utterance continues from, so an
    // over-long chunk loses its oldest end, not its newest.
    let budget = characterCap - (priorHeading.count + 1 + 2 + baseInstruction.count)
    let clipped = prior.count <= budget ? prior : String(prior.suffix(budget))
    return "\(priorHeading)\n\(clipped)\n\n\(baseInstruction)"
  }
}
