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
/// strings (`config.keyterms_prompt` — see `KeytermsBoost`), which is what the
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
/// this field **rejects** one, which is why `fitted` is no longer a
/// bandwidth-and-latency measure but the thing standing between a long history
/// and a 400.
///
/// Exercised by `Tests/BlurtEngineTests/STTPromptTests.swift`.
enum STTPrompt {
  /// Hard cap the API places on `config.stt_prompt`: 4096, and over it the
  /// request fails outright — `400 stt_prompt: String should have at most 4096
  /// characters`, before the audio is read. Unlike the budget it replaces (ours,
  /// on `conversation_context`, which the server merely trimmed), every
  /// dictation fails if this one is exceeded.
  ///
  /// Counted in **Unicode scalars**, which is measured and not a guess at what
  /// "characters" means: 4096 `é` (8192 UTF-8 bytes, 4096 scalars) is accepted,
  /// and 820 family emoji — 820 grapheme clusters but 4100 scalars — is
  /// rejected with the message above. So Swift's `String.count`, which counts
  /// graphemes, would *under*-count and let a 400 through, and UTF-8 bytes (the
  /// unit `KeytermsBoost` and `CleanupInstruction` use, where the server's own
  /// unit is unmeasured) would needlessly halve the budget for any accented
  /// text. Scalars are exactly what the server counts.
  static let characterCap = 4096

  /// What joins the turns. A newline rather than a space: the pieces are
  /// separate utterances, and running them together would invent a sentence
  /// boundary that the speaker never dictated.
  ///
  /// It costs a scalar out of `characterCap` per join, which `fitted` charges
  /// for — an off-by-one here is a 400, not a slightly long prompt.
  static let turnSeparator = "\n"

  // There is deliberately no turn cap. `ConversationContext.recentTurnCap` (99)
  // existed because `conversation_context` accepted at most 100 turns and the
  // prior chunk took the last slot; this field has no turn concept, so the
  // scalar budget is the only limit and one knob replaces two. `RecentDictations`
  // still bounds the history it draws from at 100 entries.

  /// The prompt to send for `context` — the empty string when there is nothing
  /// to say, which the encoder reads as "omit the field", so the request carries
  /// no prior text at all and the model works from the audio alone.
  ///
  /// A plain `String`, not an optional one: "nothing to send" needs exactly one
  /// spelling, and the omit-vs-`""` distinction that matters to the API is
  /// stated once on the wire, in `DictationConfig.encode(to:)`. Same shape, and
  /// the same reasoning, as `KeytermsBoost.fitted`.
  ///
  /// Every caller that reports or transmits the context goes through here — the
  /// transcriber and the developer-mode log both — so the log records exactly
  /// what went on the wire, including the trimming.
  static func text(context: TranscriptionContext?) -> String {
    guard let context else { return "" }
    let recent = context.recentTranscripts.compactMap { $0.trimmedNonEmpty() }
    guard let prior = context.priorText.trimmedNonEmpty() else {
      return fitted(recent)
    }
    // Dedupe before fitting: the prior chunk is the tail of the focused field, so
    // after a dictation it *contains* what we just pasted — which is also the
    // newest history entry. Sending both would show the model one utterance
    // twice over, and a run of dictations into one field as a stutter.
    return fitted(withoutTurnsAlreadyEnding(prior, from: recent) + [prior])
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

  /// `turns` joined and cut down to `characterCap`, keeping the newest.
  ///
  /// Drops the oldest entries first — the same end `conversation_context`'s
  /// server-side trimming dropped, so the swap didn't change which end of the
  /// history matters. The kept entries are a *contiguous* newest run: skipping an
  /// over-long one to keep an older, shorter one would hand the model a passage
  /// with a hole in the middle, which reads as continuity that never happened.
  ///
  /// One entry is clipped rather than dropped: a single entry longer than the
  /// whole budget, with nothing newer kept yet. Dropping it would send no prompt
  /// at all, so it is clipped to its *tail* — nearest the cursor is what the
  /// utterance continues from, so the oldest end is the part worth losing. (That
  /// branch can only run first, when nothing has been subtracted yet, so the clip
  /// always has the full budget to work with.) Clipping by scalar can split a
  /// grapheme cluster, which is the right trade at this boundary: the server
  /// counts scalars, so respecting graphemes here would mean sending a string it
  /// might reject.
  private static func fitted(_ turns: [String]) -> String {
    var kept: [String] = []
    var remaining = characterCap
    for turn in turns.reversed() {
      let separator = kept.isEmpty ? 0 : turnSeparator.unicodeScalars.count
      let cost = turn.unicodeScalars.count + separator
      if cost <= remaining {
        kept.append(turn)
        remaining -= cost
      } else if kept.isEmpty {
        kept.append(String(String.UnicodeScalarView(turn.unicodeScalars.suffix(remaining))))
        break
      } else {
        break
      }
    }
    return kept.reversed().joined(separator: turnSeparator)
  }
}
