/// Builds the instruction sent to the dictation API as the `prompt`
/// field of the request `config` (see `AssemblyAITranscriber`). The STT model
/// prepends this to its own system prompt.
///
/// The built prompt is *contextual priming only*: a topic hint built from the
/// window title, a destination sentence built from the focused app and field
/// label, an app-kind guidance sentence recognized from the frontmost app's
/// bundle ID (`AppKindPriming` — terminal, code editor, Slack, Obsidian),
/// "prior chunk context" (the text preceding the cursor), the selected text
/// (which the dictation replaces), and keyword boosting, all of which the
/// model is mid-trained to use for better recognition accuracy.
///
/// Three standing directives are deliberately *absent*:
/// - No annotation-suppression clause ("Transcribe without speaker labels,
///   audio event descriptions, or emotion markers."): the dictation service
///   already includes it in its own default prompt, so restating it here only
///   spent budget from `characterCap`.
/// - No "remove filler words"-style *content* reshaping: not in the model's
///   trained instruction set, so it is a no-op and is deliberately omitted
///   (see the project memory note); disfluency removal is the server-side LLM
///   rewrite's job.
/// - No language directive: pinning the prompt to English hurt non-English
///   transcription, so language is left to the model's own detection.
///
/// Output follows the trained format: the prior-chunk context and the selected
/// text lead as their own paragraphs, the location clause (topic hint +
/// destination sentence + app-kind guidance) follows, and keyword boosting
/// trails inline as `Keywords: a, b, c.` (per the mid-training
/// instruction-type reference). It stays under the API's `characterCap`: the
/// contextual blocks are clipped upstream in `FocusCapture`, and the key-terms
/// clause is fitted to the remaining budget here. Exercised by
/// `Tests/BlurtEngineTests/TranscriptionPromptTests.swift`.
enum TranscriptionPrompt {
  /// Hard cap the dictation API places on `config.prompt` ("max 4096 chars");
  /// a longer prompt risks failing the whole request, so `build` must never
  /// exceed it. The contextual blocks are all clipped upstream in
  /// `FocusCapture`; the user's key terms are the one unbounded input, so
  /// `build` fits them to whatever budget remains.
  static let characterCap = 4096

  /// Renders `context` into a transcription prompt, or `nil` when there is no usable
  /// context (the server then applies its own default prompt).
  static func build(context: TranscriptionContext?) -> String? {
    // `isEmpty` is the context type's own "no usable content" rule — the same
    // predicate `DictationSession.performPress` gates on before yielding a
    // context. Asking it here (rather than re-deriving the field-by-field test)
    // keeps a newly added context signal from being silently dropped.
    guard let context, !context.isEmpty else { return nil }
    let prior = context.priorText.trimmedNonEmpty() ?? ""
    let selected = context.selectedText.trimmedNonEmpty() ?? ""
    let app = context.appName.trimmedNonEmpty() ?? ""
    let window = context.windowTitle.trimmedNonEmpty() ?? ""
    let field = context.fieldLabel.trimmedNonEmpty() ?? ""
    let keyTerms = context.keyTerms

    // The priming blocks, separated by blank lines; keyword boosting trails
    // the last one inline:
    //   1. the prior-chunk block (`Previous transcript:\n…`, its own paragraph),
    //   2. the selected-text block (`Selected text:\n…`, what the dictation
    //      replaces — primes vocabulary/topic of the text being rewritten),
    //   3. the location clause (topic hint + destination sentence + app-kind
    //      guidance).
    var blocks: [String] = []
    if !prior.isEmpty {
      blocks.append("Previous transcript:\n\(prior)")
    }
    if !selected.isEmpty {
      blocks.append("Selected text:\n\(selected)")
    }
    // App-kind guidance ("You are dictating into a terminal …") follows the
    // destination sentence: recognized from the bundle ID, refined by the
    // window title (a code editor's title names the open file, hence the
    // language). Unrecognized apps add nothing.
    let guidance = AppKindPriming.clause(bundleID: context.bundleID, windowTitle: window) ?? ""
    let location = [locationClause(app: app, window: window, field: field), guidance]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    if !location.isEmpty {
      blocks.append(location)
    }
    var prompt = blocks.joined(separator: "\n\n")
    if !keyTerms.isEmpty {
      // Spelling priming: the user's domain vocabulary, boosted via the trained
      // inline `Keywords: a, b, c.` form (Section 2.3) trailing the context so the
      // model favors these exact spellings for names/jargon it would guess at.
      // The terms list is the one input with no upstream length cap, so include
      // only as many whole terms as `characterCap` leaves room for, so a huge
      // Settings list can't crowd out the priming itself or balloon every
      // request.
      let scaffold = prompt.isEmpty ? "Keywords: ." : " Keywords: ."
      var included: [String] = []
      var remaining = characterCap - prompt.count - scaffold.count
      for term in keyTerms {
        let cost = term.count + (included.isEmpty ? 0 : ", ".count)
        guard cost <= remaining else { break }
        included.append(term)
        remaining -= cost
      }
      if !included.isEmpty {
        let clause = "Keywords: \(included.joined(separator: ", "))."
        prompt = prompt.isEmpty ? clause : "\(prompt) \(clause)"
      }
    }
    // A context can be non-empty yet render nothing — e.g. its only signal is
    // a bundle ID no app-kind guidance recognizes. Return nil rather than an
    // empty prompt so the server default still applies.
    return prompt.trimmedNonEmpty()
  }

  /// The "where am I typing" priming clause, assembled from whichever of the
  /// app / window / field signals are present (empty when none are). Two trained
  /// shapes joined by a space: a topic hint built from the window title (the
  /// richest vocabulary signal — `This is about "…".`, mid-training §2.1) leads,
  /// and a destination sentence built from the app/field (`Dictated into …`)
  /// trails it. Each sentence ends with a period so the clause joins cleanly
  /// with the app-kind guidance that may follow it.
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
