/// Builds the dictation request's `config.conversation_context` — the dialogue
/// that came *before* this utterance, oldest turn first. The STT model reads it
/// as continuity: vocabulary, spelling, capitalization, and mid-sentence
/// continuation carry over from what came before, while only the current audio
/// is transcribed.
///
/// Not to be confused with `TranscriptionContext`, which is the local snapshot
/// taken at press time. This type is the *wire* form of the two fields on that
/// snapshot which are actually sent, in this order:
///
/// 1. **The user's recent dictations** (`recentTranscripts`) — what they said
///    into Blurt just before this press, so a multi-utterance stretch of
///    dictation reads as one continuing dialogue instead of N unrelated clips.
///    In-memory and per-launch (see `DictationSession.recentTranscripts`).
/// 2. **The text before the cursor** (`priorText`) — the last turn, because it
///    is the thing the utterance most immediately continues from: the sentence
///    the caret is sitting in.
///
/// Everything else on the snapshot stays on the machine. The frontmost app name,
/// the window title, the focused field's label, and the selected text are
/// captured for other purposes (paste spacing, the injector's window identity,
/// the developer-mode log) and **none of them go on the wire**. A field's
/// presence on `TranscriptionContext` is not permission to send it.
///
/// The key terms aren't here either, but for the opposite reason: they *are*
/// sent, as their own request field. Word boosting takes a flat list of strings
/// (`config.word_boost` — see `KeytermsBoost`), which is what the Settings
/// field collects.
///
/// **There is no `config.prompt`.** This replaced it. The prompt carried the
/// same prior chunk under a `Previous transcript:` heading plus a fixed
/// instruction, which was a prose imitation of the structured field the API
/// actually offers for exactly this job — turns, in order, trimmed by the server
/// rather than by us. Two consequences of dropping it are deliberate: the
/// service's managed default prompt applies again (a custom `prompt` replaced
/// it), and `config.language_code` is no longer ignored, which the API documents
/// as happening whenever a custom prompt is set.
///
/// That second one looked like a regression risk — the API documents
/// `language_code` as defaulting to `en`, and pinning transcription to English was
/// reverted once for hurting non-English speech. It isn't: with neither field set,
/// Spanish, French, German and Japanese clips each transcribed correctly in their
/// own language against the live endpoint. **So no language is sent at all**, and
/// adding one would only remove the detection that already works (asserted in
/// `KeytermsWireTests`).
///
/// Exercised by `Tests/BlurtEngineTests/ConversationContextTests.swift`.
enum ConversationContext {
  /// How many of the user's recent dictations lead the turn list. One short of
  /// the API's 100-turn maximum, because `priorText` takes the last slot — so a
  /// full history plus a prior chunk is exactly 100 turns and never one over. The
  /// recents are capped even when there is no prior chunk to make room for: one
  /// number to reason about, and the total then can't exceed the maximum whatever
  /// the focus capture returned.
  static let recentTurnCap = 99

  /// Cap the dictation API places on `config.conversation_context`: 4096
  /// characters summed across every turn.
  ///
  /// Counted in **characters**, not the UTF-8 bytes `KeytermsBoost` and
  /// `CleanupInstruction` use, and the difference is deliberate. Those two count
  /// bytes because over their cap the API rejects the whole request (400, before
  /// the audio is read), so the conservative unit is the safe one. This field is
  /// documented as *trimmed*, not rejected — the server drops the oldest turns
  /// itself — so fitting here is a bandwidth and latency measure, and matching
  /// the documented unit is worth more than over-shooting it.
  static let characterCap = 4096

  /// The turns to send for `context` — empty when there are none, which the
  /// encoders read as "omit the field", so the request carries no prior dialogue
  /// at all and the model works from the audio alone.
  ///
  /// A plain array, not an optional one: "no turns" needs exactly one spelling
  /// (the repo bans optional collections), and the omit-vs-`[]` distinction that
  /// *does* matter to the API is stated once on the wire, in
  /// `DictationConfig.encode(to:)`. Same shape, and the same reasoning, as
  /// `KeytermsBoost.fitted`.
  ///
  /// Every caller that reports or transmits the context goes through here — the
  /// transcriber and the developer-mode log both — so the log records exactly
  /// what went on the wire, including the trimming.
  static func turns(context: TranscriptionContext?) -> [String] {
    guard let context else { return [] }
    var recent = context.recentTranscripts.compactMap { $0.trimmedNonEmpty() }
    guard let prior = context.priorText.trimmedNonEmpty() else {
      // Trim before capping, so a blank entry can't consume one of the 99 slots.
      return fitted(Array(recent.suffix(recentTurnCap)))
    }
    // Dedupe before capping: the prior chunk is the tail of the focused field, so
    // after a dictation it *contains* what we just pasted — which is also the
    // newest history turn. Sending both would show the model one utterance as two
    // consecutive turns, and a run of dictations into one field as a stutter.
    recent = withoutTurnsAlreadyEnding(prior, from: recent)
    return fitted(Array(recent.suffix(recentTurnCap)) + [prior])
  }

  /// `recent` without the trailing turns the prior chunk already carries.
  ///
  /// Walks newest-first, peeling each matched turn off a working copy of the
  /// chunk, so several dictations into the same field collapse rather than only
  /// the last one: prior `"A. B. C."` against history `[A, B, C]` drops all three.
  /// Stops at the first turn that doesn't match — an earlier turn that isn't in
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

  /// `turns` cut down to `characterCap`, keeping the newest.
  ///
  /// Mirrors what the server does with an over-cap list — drop the oldest turns
  /// first — so the two can't disagree about which end of the dialogue matters.
  /// The kept turns are a *contiguous* newest run: skipping an over-long turn to
  /// keep an older, shorter one would hand the model a dialogue with a hole in
  /// the middle, which reads as continuity that never happened.
  ///
  /// One turn is clipped rather than dropped: a single turn longer than the
  /// whole budget, with nothing newer kept yet. Dropping it would send no
  /// context at all, so it is clipped to its *tail* — nearest the cursor is what
  /// the utterance continues from, so the oldest end is the part worth losing.
  /// (That branch can only run first, when nothing has been subtracted yet, so
  /// the clip always has the full budget to work with.)
  private static func fitted(_ turns: [String]) -> [String] {
    var kept: [String] = []
    var remaining = characterCap
    for turn in turns.reversed() {
      if turn.count <= remaining {
        kept.append(turn)
        remaining -= turn.count
      } else if kept.isEmpty {
        kept.append(String(turn.suffix(remaining)))
        break
      } else {
        break
      }
    }
    return kept.reversed()
  }
}
