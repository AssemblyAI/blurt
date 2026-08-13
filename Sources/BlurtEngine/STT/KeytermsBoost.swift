/// The user's key terms as the dictation request's `config.word_boost` — word
/// boosting, the other half of transcription steering next to
/// `ConversationContext`.
///
/// The two fields do different jobs and ride the same request:
/// `conversation_context` is the prior dialogue (the user's recent dictations,
/// then the text before the cursor) that tells the model what this utterance
/// continues; `word_boost` is a flat list of strings biasing recognition toward
/// those exact spellings. Boosting is the right tool for an explicit vocabulary
/// list — names, product names, jargon — which is exactly what the Settings
/// "Key Terms" field collects, and the wrong thing to pack into prose context (a
/// `Keywords: a, b, c.` clause is what this replaces).
///
/// **`word_boost`, not `keyterms_prompt`.** The two names are the same feature on
/// different surfaces, and the dictation API's own reference documents this one:
/// `word_boost`, "terms to bias transcription toward (names, jargon; max 2048
/// chars total)". `keyterms_prompt` is what the Sync STT surface calls it, and it
/// only ever reached the dictation engine as one of the unknown fields that
/// endpoint forwards as-is — a pass-through, not a documented parameter. Send one
/// of the two, never both: the sibling surface documents the aliases as mutually
/// exclusive ("provide only one of the three").
///
/// The terms arrive already normalized — `KeyTermsStore.parse` splits on commas,
/// trims, drops blanks, and dedupes case-insensitively — so the only thing left
/// to enforce here is length: the field accepts at most `characterCap` across
/// all terms, and the user's list is the one unbounded input in the request.
/// Exercised by `Tests/BlurtEngineTests/KeytermsBoostTests.swift`.
enum KeytermsBoost {
  /// Cap the API places on `config.word_boost`: 2048 characters summed across
  /// every term. Measured here in **UTF-8 bytes**, the conservative reading — the
  /// documented unit is "characters", which is unmeasured against the endpoint,
  /// and bytes can only overestimate a multi-byte term's cost. Same conservative
  /// choice, and the same reasoning, as `CleanupInstruction.characterCap`.
  ///
  /// Note this is the *boost* cap and a different number from the 4096 on
  /// `config.conversation_context` (`ConversationContext.characterCap`). Reusing
  /// one cap's figure for the other field is how a whole-request 400 shipped once
  /// before.
  static let characterCap = 2048

  /// The terms to send for `terms` — empty when there are none to send, which
  /// the encoders read as "omit the field", so the request asks for no boosting
  /// at all. One empty state, not two: an `[String]?` here would make "no terms"
  /// expressible twice over (the repo bans optional collections for exactly that
  /// reason), and the omit-vs-`[]` distinction that does matter belongs to the
  /// wire, where `DictationConfig.encode(to:)` states it once.
  ///
  /// Over-long lists are fitted rather than rejected: terms are taken in order
  /// while the running total fits `characterCap`, and the first one that doesn't
  /// fit stops the list. Whole terms only — half a name boosts nothing — and
  /// order is the user's, so the terms they typed first are the ones that
  /// survive a list too long to send. A term is never split and a blank one is
  /// never sent, so a stray entry can't cost the request.
  static func fitted(_ terms: [String]) -> [String] {
    var included: [String] = []
    var remaining = characterCap
    for term in terms {
      guard let term = term.trimmedNonEmpty() else { continue }
      let cost = term.utf8.count
      guard cost <= remaining else { break }
      included.append(term)
      remaining -= cost
    }
    return included
  }
}
