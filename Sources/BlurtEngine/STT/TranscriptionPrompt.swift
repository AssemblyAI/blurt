/// Builds the instruction sent to the dictation API as the `prompt`
/// field of the request `config` (see `AssemblyAITranscriber`). The STT model
/// prepends this to its own system prompt.
///
/// The prompt is deliberately minimal — two clauses, each optional:
/// - the app-kind transcription instruction (`AppKindPriming`), recognized
///   from the frontmost app's bundle ID: "Transcribe speech into markdown."
///   in Obsidian, "Transcribe speech into Swift code." in a code editor (the
///   language inferred from the window title's filename), shell commands in a
///   terminal, a casual Slack message in Slack;
/// - inline keyword boosting trailing it (`Keywords: a, b, c.`, the trained
///   §2.3 form) from the user's key terms, fitted to `characterCap`.
///
/// The rest of the captured focus context — window title, app and field
/// names, prior-cursor text, selected text — is deliberately **not** rendered:
/// real-world logs showed it crowding the instruction (VS Code, for one, parks
/// a screen-reader help announcement in the focused field's description). It
/// is still captured, feeding the dictation log, the injector's separator
/// logic, and the code-editor language refinement above. Also deliberately
/// absent:
/// - the annotation-suppression clause ("Transcribe without speaker labels,
///   audio event descriptions, or emotion markers."): the dictation service
///   already includes it in its own default prompt;
/// - a "remove filler words"-style *content* reshaping: not in the model's
///   trained instruction set, so it is a no-op (see the project memory note);
///   disfluency removal is the server-side LLM rewrite's job;
/// - a language directive: pinning the prompt to English hurt non-English
///   transcription, so language is left to the model's own detection.
///
/// Exercised by `Tests/BlurtEngineTests/TranscriptionPromptTests.swift`.
enum TranscriptionPrompt {
  /// Hard cap the dictation API places on `config.prompt` ("max 4096 chars");
  /// a longer prompt risks failing the whole request, so `build` must never
  /// exceed it. The instruction clause is a bounded sentence; the user's key
  /// terms are the one unbounded input, so `build` fits them to whatever
  /// budget remains.
  static let characterCap = 4096

  /// Renders `context` into a transcription prompt, or `nil` when there is no usable
  /// context (the server then applies its own default prompt).
  static func build(context: TranscriptionContext?) -> String? {
    // `isEmpty` is the context type's own "no usable content" rule — the same
    // predicate `DictationSession.performPress` gates on before yielding a
    // context. Asking it here (rather than re-deriving the field-by-field test)
    // keeps a newly added context signal from being silently dropped.
    guard let context, !context.isEmpty else { return nil }
    var prompt =
      AppKindPriming.clause(
        bundleID: context.bundleID, windowTitle: context.windowTitle.trimmedNonEmpty()) ?? ""
    let keyTerms = context.keyTerms
    if !keyTerms.isEmpty {
      // Spelling priming: the user's domain vocabulary, boosted via the trained
      // inline `Keywords: a, b, c.` form (Section 2.3) trailing the instruction
      // so the model favors these exact spellings for names/jargon it would
      // guess at. The terms list is the one input with no upstream length cap,
      // so include only as many whole terms as `characterCap` leaves room for,
      // so a huge Settings list can't crowd out the instruction itself or
      // balloon every request.
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
    // A context can be non-empty yet render nothing — focus signals from an
    // unrecognized app, no key terms. Return nil rather than an empty prompt
    // so the server default still applies.
    return prompt.trimmedNonEmpty()
  }
}
