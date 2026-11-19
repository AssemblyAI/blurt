import Foundation

/// Whether the rewrite in a response is a rewrite of the speech at all.
///
/// The rewrite model has one failure the response cannot flag. Given a
/// transcript its cleanup rules empty out — a lone "Yeah.", an opener it is
/// told to delete — it answers with the tail of its own instruction: the
/// user's style preferences, word for word. A lone "Um." gets a bare ".".
/// Measured against the route on 2026-11-05: 6/6 and 6/6, under every ordering
/// of the instruction tried (the preferences last, the preferences before the
/// closing rule, an explicit "return an empty response"), so the prompt cannot
/// make it go away and `llm_error` stays null. Pasted, the style text landed in
/// the user's message as a dictation.
///
/// The test is on the client: a rewrite is kept only when it says something
/// and is not a run of the instruction, else the verbatim transcript is pasted
/// (`AssemblyAITranscriber.chooseTranscript`) — what was said, cleanup or not.
/// A spoken phrase that happens to sit inside the instruction ("okay", "I don't
/// know") trips the same test and costs that utterance its cleanup, nothing
/// more.
enum RewriteGrounding {
  /// An instruction sentence shorter than this, normalized, is something a
  /// person says ("No emojis") and is not held against a rewrite.
  static let sentenceFloor = 12

  static func isSpeech(_ rewrite: String, instruction: String?) -> Bool {
    let words = normalized(rewrite)
    guard !words.isEmpty else { return false }
    guard let instruction else { return true }
    let rules = normalized(instruction)
    if rules.contains(words) { return false }
    return !sentences(of: instruction).contains { words.contains($0) }
  }

  /// Lowercased letters and digits, single-spaced. Case, punctuation and line
  /// breaks are the model's to change, so they are not what is compared.
  static func normalized(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    var gap = false
    for scalar in text.lowercased().unicodeScalars {
      guard CharacterSet.alphanumerics.contains(scalar) else {
        gap = true
        continue
      }
      if gap, !out.isEmpty { out.append(" ") }
      gap = false
      out.append(scalar)
    }
    return String(out)
  }

  /// The instruction's sentences, normalized, those long enough to be an echo
  /// rather than a phrase.
  static func sentences(of instruction: String) -> [String] {
    instruction
      .split(whereSeparator: { $0 == "." || $0 == "\n" || $0 == ":" || $0 == ";" })
      .map { normalized(String($0)) }
      .filter { $0.count >= sentenceFloor }
  }
}
