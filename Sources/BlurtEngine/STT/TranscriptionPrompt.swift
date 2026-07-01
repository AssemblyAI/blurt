/// Builds the instruction sent to AssemblyAI's Sync STT API as the `prompt`
/// field of the request `config` (see `AssemblyAITranscriber`). The Sync model
/// prepends this to its own system prompt.
///
/// Every built prompt opens with a fixed `baseInstruction` — a plain-text
/// exclusion clause (see below) — and wraps it in
/// *contextual* priming: a topic hint built from the window title, a
/// destination sentence built from the focused app and field label, "prior
/// chunk context" (the text preceding the cursor), the selected text (which the
/// dictation replaces), and keyword boosting, all of which the model is
/// mid-trained to use for better recognition accuracy.
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
/// Output follows the trained format with `baseInstruction` as its pivot: the
/// prior-chunk context, the topic hint, and the destination sentence precede it
/// as the `{context}. {baseInstruction}` shape, and keyword boosting trails it
/// inline as `Keywords: a, b, c.` (per the mid-training instruction-type
/// reference). It stays under the API's cap (`characterCap`): the contextual
/// blocks are clipped upstream in `FocusCapture`, and the key-terms clause is
/// fitted to the remaining budget here. Exercised by
/// `Tests/BlurtEngineTests/TranscriptionPromptTests.swift`.
enum TranscriptionPrompt {
  /// The standing dictation instruction prepended to the model's system prompt
  /// on every built prompt. A negative-exclusion clause (§5/§6) naming the
  /// annotation feature types the model is trained to emit, so it suppresses
  /// them. No language directive: pinning the prompt to English degraded
  /// transcription for non-English speech, so the model is left to detect the
  /// spoken language itself.
  static let baseInstruction =
    "Transcribe without speaker labels, audio event descriptions, or emotion markers."

  /// Hard cap the Sync API places on `config.prompt`; a longer prompt fails
  /// the whole request, so `build` must never exceed it. The contextual blocks
  /// are all clipped upstream in `FocusCapture`; the user's key terms are the
  /// one unbounded input, so `build` fits them to whatever budget remains.
  static let characterCap = 4096

  /// Renders `context` into a Sync STT prompt, or `nil` when there is no usable
  /// context (the server then applies its own default prompt).
  static func build(context: TranscriptionContext?) -> String? {
    guard let context else { return nil }
    let prior = context.priorText.trimmedNonEmpty() ?? ""
    let selected = context.selectedText.trimmedNonEmpty() ?? ""
    let app = context.appName.trimmedNonEmpty() ?? ""
    let window = context.windowTitle.trimmedNonEmpty() ?? ""
    let field = context.fieldLabel.trimmedNonEmpty() ?? ""
    let keyTerms = context.keyTerms
    guard
      !prior.isEmpty || !selected.isEmpty || !app.isEmpty || !window.isEmpty || !field.isEmpty
        || !keyTerms.isEmpty
    else { return nil }

    // `baseInstruction` is the pivot of the trained format. Contextual priming
    // sits *before* it; keyword boosting trails *after* it. The leading blocks,
    // separated by blank lines, precede it:
    //   1. the prior-chunk block (`Previous transcript:\n…`, its own paragraph),
    //   2. the selected-text block (`Selected text:\n…`, what the dictation
    //      replaces — primes vocabulary/topic of the text being rewritten),
    //   3. the location clause (topic hint + destination sentence).
    var blocks: [String] = []
    if !prior.isEmpty {
      blocks.append("Previous transcript:\n\(prior)")
    }
    if !selected.isEmpty {
      blocks.append("Selected text:\n\(selected)")
    }
    let location = locationClause(app: app, window: window, field: field)
    // The topic hint and `baseInstruction` share one line as the trained
    // `{context}. {baseInstruction}` shape; with no topic it's the bare base.
    let instruction = location.isEmpty ? baseInstruction : "\(location) \(baseInstruction)"
    blocks.append(instruction)
    var prompt = blocks.joined(separator: "\n\n")
    if !keyTerms.isEmpty {
      // Spelling priming: the user's domain vocabulary, boosted via the trained
      // inline `Keywords: a, b, c.` form (Section 2.3) trailing the marker so the
      // model favors these exact spellings for names/jargon it would guess at.
      // The terms list is the one input with no upstream length cap, so include
      // only as many whole terms as `characterCap` leaves room for — a huge
      // Settings list must not push the prompt over the cap and fail every
      // dictation with a 400.
      var included: [String] = []
      var remaining = characterCap - prompt.count - " Keywords: .".count
      for term in keyTerms {
        let cost = term.count + (included.isEmpty ? 0 : ", ".count)
        guard cost <= remaining else { break }
        included.append(term)
        remaining -= cost
      }
      if !included.isEmpty {
        prompt += " Keywords: \(included.joined(separator: ", "))."
      }
    }
    return prompt
  }

  /// The "where am I typing" priming clause, assembled from whichever of the
  /// app / window / field signals are present (empty when none are). Two trained
  /// shapes joined by a space: a topic hint built from the window title (the
  /// richest vocabulary signal — `This is about "…".`, mid-training §2.1) leads,
  /// and a destination sentence built from the app/field (`Dictated into …`)
  /// trails it. Each sentence ends with a period so the clause joins cleanly
  /// before `baseInstruction`.
  private static func locationClause(app: String, window: String, field: String) -> String {
    let topic = window.isEmpty ? "" : "This is about \"\(window)\"."

    let destination: String
    switch (app.isEmpty, field.isEmpty) {
    case (false, false): destination = "Dictated into \(app), in the \"\(field)\" field."
    case (false, true): destination = "Dictated into \(app)."
    case (true, false): destination = "Dictated in the \"\(field)\" field."
    case (true, true): destination = ""
    }

    return [topic, destination].filter { !$0.isEmpty }.joined(separator: " ")
  }
}
