/// Key terms — names, product names, jargon — for the dictation request's
/// `config.keyterms_prompt`: keyterms prompting, the other half of
/// transcription steering next to the `stt_prompt` context.
///
/// The two fields do different jobs and ride the same request:
/// `stt_prompt` is prior text (recent dictations, then the text before the
/// cursor) that tells the model what this utterance continues;
/// `keyterms_prompt` is a flat list of strings biasing recognition toward those
/// exact spellings. Boosting is the right tool for an explicit vocabulary list,
/// and the wrong thing to pack into prose context (a `Keywords: a, b, c.`
/// clause).
///
/// **`keyterms_prompt`, not `word_boost`.** Three names are the same feature —
/// `keyterms_prompt` is the one the Streaming and Pre-recorded surfaces use and
/// the one the dictation reference documents, with `keyterms` and `word_boost`
/// kept as legacy aliases. Measured against `/v1/transcribe/live`: the route
/// validates its config strictly and rejects an unknown key outright
/// (`Extra inputs are not permitted`), and the service's own error names it
/// first: `provide only one of keyterms_prompt, keyterms, or word_boost`. The
/// aliases are mutually exclusive on this route, so a request carrying two names
/// 400s before the audio is read. Send exactly one.
///
/// Two steps, both here: `parse` turns what a person types (a comma-separated
/// list) into clean terms, and `fitted` keeps a list within the field's two
/// caps, which the user's list is the one unbounded input able to breach.
public enum KeyTerms {
  /// A comma-separated list as clean terms: split on commas (only commas, so
  /// "San Francisco" stays one term), trimmed, blanks dropped, and duplicates
  /// removed case-insensitively, keeping the first spelling and the user's
  /// order. `fitted` assumes terms arrive this way.
  public static func parse(_ text: String?) -> [String] {
    guard let text else { return [] }
    var seen = Set<String>()
    var result: [String] = []
    for piece in text.split(separator: ",") {
      guard let term = String(piece).trimmedNonEmpty() else { continue }
      guard seen.insert(term.lowercased()).inserted else { continue }
      result.append(term)
    }
    return result
  }

  /// Terms as the comma-separated text `parse` reads back unchanged.
  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  public static func join(_ terms: [String]) -> String {
    terms.joined(separator: ", ")
  }

  /// Cap the API places on `config.keyterms_prompt`: 2048 characters summed
  /// across every term. Measured here in **UTF-8 bytes**, the conservative reading — the
  /// documented unit is "characters", which is unmeasured against the endpoint,
  /// and bytes can only overestimate a multi-byte term's cost.
  ///
  /// Note this is the *boost* cap and a different number from the 4096 on
  /// `config.stt_prompt`. Reusing
  /// one cap's figure for the other field is how a whole-request 400 shipped once
  /// before.
  public static let characterCap = 2048

  /// The *other* cap on the same field, and the one the byte budget above does
  /// not imply: at most **100 terms**, however short they are
  /// (`keyterms_prompt: maxItems: 100` in the reference, alongside its "Maximum
  /// 100 terms and 8000 characters in total"). Exceeding either is a 400 on the
  /// whole request, before the audio is read.
  ///
  /// Reachable, which is why it is here: terms comma-split from one free-text
  /// field (`parse`) are uncounted, so 150 short ones cost ~1500 bytes and sail under
  /// `characterCap` while being half again over this. That shape failed *every*
  /// dictation until the user shortened the list — the same outage a 3057-character
  /// cleanup instruction caused once, by the same mechanism.
  public static let termCap = 100

  /// The terms to send for `terms` — empty when there are none to send, which
  /// the encoders read as "omit the field", so the request asks for no boosting
  /// at all. One empty state, not two: an `[String]?` here would make "no terms"
  /// expressible twice over (the repo bans optional collections for exactly that
  /// reason), and the omit-vs-`[]` distinction that does matter belongs to the
  /// wire, where `DictationConfig.encode(to:)` states it once.
  ///
  /// Over-long lists are fitted rather than rejected: terms are taken in order
  /// while the running total fits `characterCap` **and** the list is under
  /// `termCap`, and the first term that breaches either stops the list. Two
  /// independent limits, so both are checked — a list can be well under the byte
  /// budget and still over the count. Whole terms only — half a name boosts
  /// nothing — and order is the user's, so the terms they typed first are the
  /// ones that survive a list too long to send. A term is never split and a
  /// blank one is never sent, so a stray entry can't cost the request.
  public static func fitted(_ terms: [String]) -> [String] {
    var included: [String] = []
    var remaining = characterCap
    for term in terms {
      guard included.count < termCap else { break }
      guard let term = term.trimmedNonEmpty() else { continue }
      let cost = term.utf8.count
      guard cost <= remaining else { break }
      included.append(term)
      remaining -= cost
    }
    return included
  }
}
