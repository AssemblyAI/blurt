/// Fits the dictation request's `config.stt_prompt` — the text that came
/// before the utterance, as passages oldest-first — to what the route accepts:
/// joined by newlines and cut to `characterCap`, oldest passages first. What
/// goes into it is the caller's (Blurt's is `BlurtAssemblyAI`'s `STTPrompt`);
/// this holds the field's limits, the same shape as `KeyTerms.fitted` for
/// `keyterms_prompt`.
public enum DictationPrompt {
  /// Hard cap the API places on `config.stt_prompt`: 4096, and over it the
  /// request fails outright — `400 stt_prompt: String should have at most 4096
  /// characters`, before the audio is read. Unlike the budget it replaces (ours,
  /// on `conversation_context`, which the server merely trimmed), every
  /// dictation fails if this one is exceeded.
  ///
  /// **The reference says 6000** (`stt_prompt: maxLength: 6000`) and 4096 is
  /// still the right number, because the route validates this field **twice**.
  /// Measured up the ladder, 2026-09-11:
  ///
  /// | length | response                                                      |
  /// | ------ | ------------------------------------------------------------- |
  /// | 4096   | 200                                                           |
  /// | 4097   | `400 invalid config part: prompt: … at most 4096 characters`   |
  /// | 6000   | `400 invalid config part: prompt: … at most 4096 characters`   |
  /// | 6001   | `400 stt_prompt: String should have at most 6000 characters`   |
  ///
  /// Read the field *names* in those two messages. Over 6000 the outer envelope
  /// rejects `stt_prompt` — the documented cap, and the only one the reference
  /// describes. Between 4097 and 6000 the request clears that envelope and is
  /// then rejected by the engine behind it, which knows the field by its **legacy
  /// alias** `prompt` and caps it at 4096.
  ///
  /// So the documented 6000 is the field's real cap and the 4096 is the
  /// deprecated path's, still sitting in front of it. 4096 is what a request has
  /// to fit today, and it is safe under both numbers — being under a cap costs
  /// prompt budget, being over one fails every dictation carrying a long
  /// history. This is the one place the repo runs tighter than the docs on
  /// purpose. Raising it to the documented 6000 is the right end state and takes
  /// one re-measurement at 4097 to confirm the inner validator is gone; until
  /// that measurement says 200, don't.
  ///
  /// Counted in **Unicode scalars**, which is measured and not a guess at what
  /// "characters" means: 4096 `é` (8192 UTF-8 bytes, 4096 scalars) is accepted,
  /// and 820 family emoji — 820 grapheme clusters but 4100 scalars — is
  /// rejected with the message above. So Swift's `String.count`, which counts
  /// graphemes, would *under*-count and let a 400 through, and UTF-8 bytes (the
  /// unit `KeyTerms` uses, where the server's own unit is unmeasured) would
  /// needlessly halve the budget for any accented text. Scalars are exactly what the server counts.
  static let characterCap = 4_096

  /// What joins the turns. A newline rather than a space: the pieces are
  /// separate utterances, and running them together would invent a sentence
  /// boundary that the speaker never dictated.
  ///
  /// It costs a scalar out of `characterCap` per join, which `fitted` charges
  /// for — an off-by-one here is a 400, not a slightly long prompt.
  static let separator = "\n"

  // There is deliberately no turn cap: `conversation_context` accepted at most
  // 100 turns, but this field has no turn concept, so the scalar budget is the
  // only limit.

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
  public static func fitted(_ turns: [String]) -> String {
    var kept: [String] = []
    var remaining = characterCap
    for turn in turns.reversed() {
      let joinCost = kept.isEmpty ? 0 : Self.separator.unicodeScalars.count
      let cost = turn.unicodeScalars.count + joinCost
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
    return kept.reversed().joined(separator: Self.separator)
  }
}
