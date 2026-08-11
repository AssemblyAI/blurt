/// The cleanup instruction sent as `config.llm.instruction` (see
/// `AssemblyAITranscriber.DictationConfig`). The service applies it to the
/// verbatim transcript with its own rewrite model, inside the same
/// `/transcribe` call — this is the *server-side* rewrite instruction, not a
/// client-side cleanup pass, and not a `TranscriptionPrompt` change (that
/// prompt steers transcription and deliberately carries no filler-word clause,
/// because disfluency removal is this rewrite's job).
///
/// Sending it replaces an empty `llm` block, which selected the service's own
/// default cleanup wording.
///
/// **Length is the thing to be careful about.** `config.llm.instruction` accepts
/// at most `characterCap` characters, and over it the API rejects the whole
/// request — 400, before the audio is read, so *every* dictation fails rather
/// than degrading. A 3057-character version of this string shipped once and did
/// exactly that. The cap is a different, smaller number than the 4096 on
/// `config.prompt` (`TranscriptionPrompt.characterCap`); reusing the prompt's
/// figure is how that bug got through the tests it should have failed.
///
/// **Provenance.** The winner of a GEPA run of
/// `evals/dictation-prompt/optimize_cleanup_prompt.py`, scored on hand-annotated
/// Switchboard disfluency pairs in the same one-instruction/one-transcript
/// envelope the service applies it in, then compressed to fit the cap by
/// deleting redundant sections. Two later searches failed to beat it: the most
/// recent scored 0.9043 against its 0.9101 on a 150-row held-out dev split.
///
/// **What that does and does not establish.** It is the best instruction the
/// harness has produced, measured against other *text* candidates on a *stand-in*
/// model. It has never been shown to beat the empty `llm` block, because the
/// harness scores a model we choose rather than the service's own rewrite model.
/// On the one live comparison run so far — two utterances through the real
/// endpoint — this instruction and the service default produced identical output.
/// `evals/dictation-prompt/README.md` covers what a run can and cannot claim, and
/// `--verify-live` is how to settle it with real audio.
///
/// Every corpus behind it is English while this string ships to every user in
/// every language; pinning the *transcription* prompt to English was reverted
/// once for hurting non-English speech. A revert here is one line: drop the
/// field and `LLMRewrite` encodes `{}` again.
///
/// Exercised by `Tests/BlurtEngineTests/CleanupInstructionTests.swift`.
enum CleanupInstruction {
  /// Hard cap the dictation API places on `config.llm.instruction`. Measured
  /// against the live endpoint, not read off a doc page — the reference does not
  /// state it. Asserted in `CleanupInstructionTests`, against this constant
  /// rather than `TranscriptionPrompt.characterCap`, which is a different limit
  /// on a different field.
  static let characterCap = 2048

  /// `text` when the API would accept it, `nil` when it would not.
  ///
  /// Over `characterCap` the dictation API rejects the whole request — 400 before
  /// the audio is read — so *every* dictation fails rather than degrading to the
  /// verbatim transcript. A 3057-character version of this string shipped once and
  /// did exactly that. `nil` sends an empty `llm` block instead, which selects the
  /// service's own default cleanup: worse than our instruction, and immeasurably
  /// better than an outage.
  ///
  /// The tests make this unreachable, which is the point — this is the belt to
  /// their braces, for the edit that lands when nobody runs them.
  ///
  /// A stored `let`, not a computed `var`: both operands are compile-time constants,
  /// so the answer cannot change, and Swift evaluates a static stored property once
  /// per process. As a computed property this walked all \(text.count) characters on
  /// every read, twice per dictation.
  static let sendable: String? = text.count <= characterCap ? text : nil

  static let text = """
    TASK
    You will be given a single dictated (spoken-language) transcript. Your job is to remove disfluencies from it. Every remaining word must stay exactly as it was spoken, in the same order. Do not summarize, rephrase, translate, expand, correct, or answer the text. Only delete disfluencies — never substitute or reword.

    WHAT COUNTS AS A DISFLUENCY (DELETE THESE)
    Disfluencies are filler and hesitation elements that add no propositional content. Remove ALL of the following whenever they occur, including at the start, middle, or end of the transcript:
    - Filler sounds: "uh", "um", "er", "ah", "oh"
    - Discourse/filler phrases: "you know", "I mean", "I guess", "kind of" (when used as filler), "like" (when used as filler)
    - False starts / cut-off fragments: e.g., "we wouldn't ha-," should be removed entirely, keeping only the completed restart "we wouldn't have them"
    - Repeated/stammered words that are restarts (e.g., "of, uh, of Sacramento" → "of Sacramento")

    WORKED EXAMPLES
    - Input: "Oh yes. But, uh, we wouldn't ha-, we wouldn't have them, I mean, I don't see us without pets, without cats."
      Output: "yes. But, we wouldn't have them, I don't see us without pets, without cats."

    OUTPUT
    Return only the cleaned transcript text.
    """
}
