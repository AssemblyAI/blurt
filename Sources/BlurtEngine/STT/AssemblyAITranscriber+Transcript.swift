import AssemblyAI
import Foundation

/// Which of a response's two transcripts is pasted — the enhanced-transcripts
/// switch, and the one place a rewrite that is not a rewrite of the speech
/// (`RewriteGrounding`) is turned away.
extension AssemblyAITranscriber {
  /// Which of the two transcripts in the response to paste.
  ///
  /// **This is the enhanced-transcripts switch.** The config always asks for the
  /// rewrite, so both transcripts are in hand by the time this runs and the
  /// setting is a pure choice between them: off means paste `text` exactly as
  /// spoken, on means prefer the rewrite. Read fresh per request, so a toggle
  /// applies to the next dictation without rebuilding the transcriber.
  ///
  /// It used to be a *request* switch — an explicit null `llm`, the only off
  /// state the route has, since omitting the instruction merely selects the
  /// service's own default cleanup. Deciding here instead costs a rewrite the
  /// user never sees: with the setting off they still wait out its ~5 s
  /// server-side budget and are still billed for it. What it buys is one request
  /// shape to reason about, and a switch that cannot disagree with the response
  /// it was applied to.
  ///
  /// With the setting on, the rewrite is best-effort, so anything unusable
  /// degrades to the verbatim transcript rather than an error. Blank counts as
  /// unusable alongside null: the service nulls out an empty rewrite, but a ""
  /// slipping through would strand the utterance — the pipeline drops a
  /// whitespace-only transcript to `.idle` without pasting or reporting, wasting
  /// the good verbatim `text` beside it.
  ///
  /// `instruction` is the `llm_instruction` the request carried, so a rewrite
  /// that is that instruction read back (`RewriteGrounding`) is caught here too.
  func transcript(from response: DictationResponse, enhanced: Bool, instruction: String?) -> String {
    let chosen = Self.chooseTranscript(
      verbatim: response.text, rewrite: response.llmResponse, enhanced: enhanced, instruction: instruction)
    if enhanced, chosen != response.llmResponse {
      if let error = response.llmError {
        Self.log.warning(
          "llm rewrite unavailable (\(error, privacy: .public)); using verbatim transcript")
      } else if response.llmResponse.trimmedNonEmpty() != nil {
        Self.log.notice("llm rewrite is not a rewrite of the speech; using verbatim transcript")
      }
    }
    return chosen
  }

  /// The choice itself, pure: the verbatim transcript, or the rewrite when
  /// enhanced transcripts are on and there is something to rewrite.
  ///
  /// A dictation that caught no speech comes back with an empty `text` — and,
  /// since every request carries the user's style instruction, a rewrite the
  /// model wrote from the instruction alone. Nothing spoken means nothing to
  /// paste, whatever the rewrite says.
  ///
  /// Speech the cleanup rules empty out ("Yeah.") gets the same rewrite — the
  /// instruction's own tail, the user's style preferences word for word, which
  /// on the phone was pasted as a dictation (2026-11-05). `instruction` is what
  /// the request carried; a rewrite that is a run of it, or that says nothing
  /// ("."), is not a rewrite of the speech and loses to the verbatim transcript
  /// (`RewriteGrounding`).
  static func chooseTranscript(verbatim: String, rewrite: String?, enhanced: Bool, instruction: String? = nil)
    -> String
  {
    guard enhanced, verbatim.trimmedNonEmpty() != nil, let rewrite = rewrite.trimmedNonEmpty() else {
      return verbatim
    }
    return RewriteGrounding.isSpeech(rewrite, instruction: instruction) ? rewrite : verbatim
  }
}
