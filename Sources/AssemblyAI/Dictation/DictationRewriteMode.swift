// The dictation API's JSON contract: the `config` part `DictationClient`
// encodes, and the success/error bodies it decodes. `DictationClient.swift` is
// the transport (multipart framing, timeouts, metrics); these files are the wire
// shape. Top-level and public: callers outside the SDK build the config and
// read the response.
//
// Every field name here was swept against the live route on 2026-09-10, because
// the route validates its config **strictly**: an unrecognized key earns
// `400 invalid config part: <key>: Extra inputs are not permitted`, exactly as a
// deliberately bogus one does. The reference says the opposite about this
// endpoint — "Over HTTP, unknown fields are forwarded to the transcription
// engine as-is" — but re-measured 2026-09-11, a config carrying
// `blurt_probe_bogus_key: 1` earns `400 invalid config part:
// blurt_probe_bogus_key: Extra inputs are not permitted`.
//
// **The docs are the source of truth for what to send, and that disagreement
// does not change what this file does**: every key below is one the reference
// documents, so nothing here depends on unknown fields being either forwarded or
// rejected. Keep it that way and the question stays academic.
//
// The corollary is the one that bites. The route *accepts* more names than the
// reference lists — `prompt`, `keyterms`, `word_boost` and `language_code` are
// all live, and the docs call the first three legacy aliases — so a 200 is not
// evidence a field is supported, only that it has not been removed yet. There
// has been a lot of renaming on this route. Treat any name absent from the docs
// as deprecated and don't send it, however well it works today.
/// The models the cleanup rewrite can run on — `config.rewrite_mode`'s
/// documented values. Typed so a misspelling can't type-check its way onto the
/// wire.
public enum DictationRewriteMode: String, Encodable, Sendable {
  /// The route's default.
  case fast
  /// A larger model: better rewrites, a longer server-side path.
  case smart
}
