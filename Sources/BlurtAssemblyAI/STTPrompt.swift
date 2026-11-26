import AssemblyAI
import BlurtEngine

/// Builds the dictation request's `config.stt_prompt` — the contextual prompt
/// that primes the STT model with what came *before* this utterance. The model
/// reads it as continuity: vocabulary, spelling, capitalization, and mid-sentence
/// continuation carry over from that text, while only the current audio is
/// transcribed.
///
/// Not to be confused with `TranscriptionContext`, which is the local snapshot
/// taken at press time. This type is the *wire* form of the two fields on that
/// snapshot which are actually sent, joined oldest-first in this order:
///
/// 1. **The user's recent dictations** (`recentTranscripts`) — what they said
///    into Blurt just before this press, so a multi-utterance stretch of
///    dictation reads as one continuing passage instead of N unrelated clips.
///    In-memory and per-launch (see `DictationSession.recentTranscripts`).
/// 2. **The text before the cursor** (`priorText`) — last, because it is the
///    thing the utterance most immediately continues from: the sentence the
///    caret is sitting in.
///
/// Everything else on the snapshot stays on the machine. The frontmost app name,
/// the window title, the focused field's label, and the selected text are
/// captured for other purposes (paste spacing, the injector's window identity,
/// the developer-mode log) and **none of them go on the wire**. A field's
/// presence on `TranscriptionContext` is not permission to send it.
///
/// The key terms aren't here either, but for the opposite reason: they *are*
/// sent, as their own request field. Keyterms prompting takes a flat list of
/// strings (`config.keyterms_prompt` — see `KeyTerms`), which is what the
/// Settings field collects. Don't fold them into this string — a
/// `Keywords: a, b, c.` clause is the shape that field replaced.
///
/// **Prose, not turns, and not instructions.** This carries the prior text and
/// nothing else: no `Previous transcript:` heading, no "continue mid-sentence"
/// directive. The service documents this field as a *description of the audio*
/// rather than a command to the model, and it applies its own managed
/// transcription behaviour on top; an instruction here competes with that
/// instead of adding to it. Whether a framing sentence would score better than a
/// bare join is an eval question (`evals/dictation-prompt/` is the harness
/// shaped for it), not a matter of taste to settle in this file.
///
/// **`stt_prompt` and `prompt` are the same field.** The service rejects a
/// request carrying both — `provide only one of stt_prompt or prompt; they are
/// the same field` — so the two names are aliases, and `stt_prompt` is the one
/// the dictation route documents. This replaced `config.conversation_context`,
/// which carried the same two signals as an ordered array of turns; both fields
/// exist and can ride the same request (measured), so the swap is a choice about
/// which one steers, not something the API forced.
///
/// What the swap costs, recorded so nobody rediscovers it: the turn boundaries
/// (this field is one string, so the model infers them from the newlines), and
/// server-side trimming — `conversation_context` trimmed an over-cap list and
/// this field **rejects** one, which is why `DictationPrompt.fitted` is no longer a
/// bandwidth-and-latency measure but the thing standing between a long history
/// and a 400.
///
/// Exercised by `Tests/BlurtEngineTests/STTPromptTests.swift`.
enum STTPrompt {
  /// The prompt to send for `context` — the empty string when there is nothing
  /// to say, which the encoder reads as "omit the field", so the request carries
  /// no prior text at all and the model works from the audio alone.
  ///
  /// A plain `String`, not an optional one: "nothing to send" needs exactly one
  /// spelling, and the omit-vs-`""` distinction that matters to the API is
  /// stated once on the wire, in `DictationConfig.encode(to:)`. Same shape, and
  /// the same reasoning, as `KeyTerms.fitted`.
  ///
  /// The transcriber both sends this and reports it to the developer-mode log
  /// (`AssemblyAITranscriber.contextPrompt(for:)`), so the log records exactly
  /// what went on the wire, including the trimming.
  static func text(context: TranscriptionContext?) -> String {
    guard let context else {
      return ""
    }
    let recent = context.recentTranscripts.compactMap { $0.trimmedNonEmpty() }
    // Scrubbed here, where the wire string is built, rather than at capture:
    // the log's `prior` and the paste separator read the field text as it was.
    let scrubbed = context.priorText.map { prior in
      TextShortcutExpander.redactingExpansions(in: prior, using: context.textShortcuts)
    }
    guard let prior = scrubbed.trimmedNonEmpty() else {
      return DictationPrompt.fitted(recent)
    }
    // Dedupe before fitting: the prior chunk is the tail of the focused field, so
    // after a dictation it *contains* what we just pasted — which is also the
    // newest history entry. Sending both would show the model one utterance
    // twice over, and a run of dictations into one field as a stutter.
    return DictationPrompt.fitted(withoutTurnsAlreadyEnding(prior, from: recent) + [prior])
  }

  /// `recent` without the trailing entries the prior chunk already carries.
  ///
  /// Walks newest-first, peeling each matched entry off a working copy of the
  /// chunk, so several dictations into the same field collapse rather than only
  /// the last one: prior `"A. B. C."` against history `[A, B, C]` drops all three.
  /// Stops at the first entry that doesn't match — an earlier one that isn't in
  /// the chunk means the run was interrupted (a different field, or the user typed),
  /// and everything before it is genuine history the chunk cannot speak for.
  ///
  /// Matching is on the trimmed tail, since the paste inserts a leading separator
  /// and the field may hold trailing whitespace of its own.
  private static func withoutTurnsAlreadyEnding(_ prior: String, from recent: [String]) -> [String] {
    var kept = recent
    var tail = prior
    while let newest = kept.last, tail.hasSuffix(newest) {
      tail = String(tail.dropLast(newest.count))
      while let last = tail.last, last.isWhitespace { tail.removeLast() }
      kept.removeLast()
    }
    return kept
  }
}
