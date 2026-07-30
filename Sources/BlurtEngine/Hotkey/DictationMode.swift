/// Which of the two dictation triggers started a session, and therefore what
/// the pasted text should be.
///
/// Blurt binds two lone-modifier keys (see `DictationTriggerPair`): one for the
/// **raw** verbatim transcript and one for the **cleaned-up** server-side LLM
/// rewrite. The mode rides from the key that fired (`DualTriggerRouter`) through
/// `DictationSession` into the transcribe request, where `cleansUp` decides
/// whether the dictation API's `llm` cleanup-rewrite block is included — raw
/// omits it (the verbatim `text` is pasted), cleaned includes it (the rewrite
/// is pasted). It is the pipeline's single source of "which transcript did the
/// user ask for", so the two keys can't disagree with the request they build.
public enum DictationMode: Sendable, Hashable, CaseIterable {
  /// Verbatim transcript — the request omits the `llm` block, so the service
  /// skips its cleanup rewrite and the words are pasted exactly as spoken.
  case raw
  /// Cleaned-up transcript — the request carries the `llm` block, so the
  /// service runs its cleanup rewrite (disfluencies removed, punctuation fixed)
  /// and that polished text is pasted.
  case cleaned

  /// Whether this mode asks the dictation API for its server-side cleanup
  /// rewrite. Read at request-build time to decide the `llm` block's presence.
  /// Internal (not public): only the engine's pipeline reads it — the app just
  /// forwards the opaque `DictationMode` — so exposing it would trip periphery's
  /// redundant-public check, the same reason the former enhanced-transcripts
  /// switch kept its accessor internal.
  var cleansUp: Bool { self == .cleaned }
}
