/// Renders a `TranscriptionContext` into the two request-customization fields
/// the dictation API accepts, each of which has one job (see
/// `AssemblyAITranscriber` for the wire encoding):
///
/// - `conversation_context` — the text immediately before the insertion point,
///   as a single turn. This is real left-context: it tells the model what the
///   utterance is continuing, which is what fixes mid-sentence casing and
///   proper-noun consistency.
/// - `keyterms_prompt` — the user's key terms, verbatim, as the explicit
///   vocabulary list the field is for.
///
/// **`config.prompt` is deliberately never sent.** The field takes a
/// *description of the audio* ("Cardiology consultation about chest pain
/// symptoms."), not instructions — transcription behavior is optimized out of
/// the box, so an imperative like "Transcribe speech into markdown." was aimed
/// at a field that does not act on instructions. That is also why the key terms
/// ride in `keyterms_prompt` rather than being packed into the prompt as a
/// `Keywords:` clause. Sending no prompt keeps the service's managed default —
/// a custom prompt replaces it wholesale, including its language steering,
/// which is the mechanism behind the earlier finding that pinning the prompt to
/// English hurt non-English speech.
///
/// **Nothing describing the destination app is sent either.** An earlier
/// version recognized the frontmost app's bundle ID as a *kind* (terminal, code
/// editor, Slack, Obsidian) and sent a matching formatting clause as
/// `llm.instruction`. That is gone: the `llm` block now carries no instruction,
/// so the service's own default cleanup rewrite applies to every utterance
/// regardless of where the text is going.
///
/// Blurt has no earlier turns to send: `conversation_context` carries exactly
/// one entry, the prior-cursor text, or none.
///
/// The rest of the captured context is not sent at all. The app name and field
/// label render nowhere (real-world logs showed them crowding the request — VS
/// Code parks a screen-reader help announcement in the focused field's
/// description), and the window title is read only to anchor the injector's
/// paste separator. Selected text is never priming: the paste replaces it, so
/// conditioning the model on it would prime for text on its way out.
///
/// Exercised by `Tests/BlurtEngineTests/TranscriptionSteeringTests.swift`.
enum TranscriptionSteering {
  /// What one utterance sends beyond the audio and its geometry. Built here so
  /// the transcriber and the dictation log describe the same request rather than
  /// each deriving it.
  struct Fields: Sendable, Equatable {
    /// Turns preceding this utterance, oldest first. At most one entry (the
    /// prior-cursor text).
    let conversationContext: [String]
    /// Explicit vocabulary to bias recognition toward, in the user's own
    /// spelling and capitalization.
    let keyterms: [String]

    /// Nothing to customize — every field omitted, so the service applies its
    /// managed default prompt and its default cleanup rewrite. Also the value
    /// to compare against for "does this utterance customize anything?" —
    /// `Fields` is `Equatable`, so no separate emptiness predicate exists to
    /// drift from the fields themselves.
    static let empty = Fields(conversationContext: [], keyterms: [])
  }

  /// Cap the dictation API documents for `conversation_context`: 4096 characters
  /// across all turns. Over-cap context is trimmed rather than rejected, so this
  /// is a quality guard, not a request-failure guard — but the clip must keep the
  /// *tail*, since the words nearest the insertion point are the ones carrying
  /// continuity. `FocusCapture` already caps prior text far below this
  /// (`maxPriorChars`, 320); the guard is here so a hand-built or future-widened
  /// context can't silently exceed the field.
  static let conversationContextCharacterCap = 4096

  /// Cap the dictation API documents for `keyterms_prompt`: 2048 characters
  /// totalled across every term. Key terms are the one input with no upstream
  /// length limit — a Settings list of any size — so `build` includes only as
  /// many whole leading terms as fit.
  static let keytermsCharacterCap = 2048

  /// Renders `context` into the fields to send. An absent or unusable context
  /// yields `.empty`, which sends no customization at all.
  static func build(context: TranscriptionContext?) -> Fields {
    // `isEmpty` is the context type's own "no usable content" rule — the same
    // predicate `DictationSession.performPress` gates on before yielding a
    // context. Asking it here (rather than re-deriving the field-by-field test)
    // keeps a newly added context signal from being silently dropped.
    guard let context, !context.isEmpty else { return .empty }
    return Fields(
      conversationContext: priorTurn(of: context).map { [$0] } ?? [],
      keyterms: fittedKeyterms(context.keyTerms))
  }

  /// The prior-cursor text as one conversation turn, clipped to the field's cap
  /// from the front so the text nearest the insertion point survives.
  private static func priorTurn(of context: TranscriptionContext) -> String? {
    guard let prior = context.priorText.trimmedNonEmpty() else { return nil }
    guard prior.count > conversationContextCharacterCap else { return prior }
    return String(prior.suffix(conversationContextCharacterCap))
  }

  /// As many whole leading terms as the total-length cap allows. Whole terms
  /// only: half a proper noun biases the model toward a spelling nobody wants.
  private static func fittedKeyterms(_ terms: [String]) -> [String] {
    var included: [String] = []
    var remaining = keytermsCharacterCap
    for term in terms {
      guard term.count <= remaining else { break }
      included.append(term)
      remaining -= term.count
    }
    return included
  }
}
