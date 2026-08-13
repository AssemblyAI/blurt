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
/// Exercised by `Tests/BlurtEngineTests/ConversationContextTests.swift`.
enum ConversationContext {
  /// How many of the user's recent dictations lead the turn list. One short of
  /// the API's 100-turn maximum, because `priorText` takes the last slot — so a
  /// full history plus a prior chunk is exactly 100 turns and never one over.
  /// The recents are capped even when there is no prior chunk to make room for:
  /// one number to reason about, and the total can then never exceed the API's
  /// whatever the focus capture returned.
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
    // Trim before capping, so a blank entry can't consume one of the 99 slots.
    var turns = Array(
      context.recentTranscripts.compactMap { $0.trimmedNonEmpty() }.suffix(recentTurnCap))
    if let prior = context.priorText.trimmedNonEmpty() { turns.append(prior) }
    return fitted(turns)
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
