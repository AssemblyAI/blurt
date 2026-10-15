import AssemblyAI
import Foundation

/// Storage for the user's dictation "key terms" — a comma-separated list of
/// domain words (names, jargon, product names) sent as the dictation request's
/// keyterms list (`config.keyterms_prompt`, see the SDK's `KeyTerms`), so the model
/// favors those exact spellings. They used to ride the transcription `prompt` as
/// a `Keywords: a, b, c.` clause instead; a flat list is the field the API
/// provides for exactly this, so that is what they are now.
///
/// Unlike the API key these aren't secret, so they live in `UserDefaults` rather
/// than the Keychain. The transcription pipeline reads the parsed list via
/// `terms`; the editor reads the raw string via `raw`. Same shape as
/// `DeveloperModeStore` / `EnhancedTranscriptsStore` — a struct taking its
/// `UserDefaults` — rather than the static-`.standard` enum it used to be: the
/// read side could only be exercised against the process's real defaults, so its
/// suite had to be `.serialized` and to save and restore the developer's own
/// stored terms around every case, which a crash mid-test left overwritten.
///
/// Read-only by design: the Settings field binds `@AppStorage` straight to
/// `defaultsKey`, which is the sole writer. There is deliberately no setter —
/// normalizing on write fought the text field, because the trimmed value was
/// pushed back into the binding as an external change and a trailing space was
/// deleted as the user typed it. Normalization lives on the read side instead
/// (`raw` trims, `KeyTerms.parse` trims and dedupes), so a blank field still reads back
/// as "no terms". See the note on `KeyTermsStepView.text`.
public struct KeyTermsStore {
  /// `UserDefaults` key for the raw, comma-separated string the user typed.
  /// Public so the Settings field can bind `@AppStorage` to it and so the app
  /// can clear it when resetting to a clean state under UI testing (matching
  /// `TriggerKeyStore`/`SoundPackStore`).
  public static var defaultsKey: String { DefaultsKey.keyTerms.key }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The raw comma-separated string exactly as the user entered it (preserving
  /// their spacing/order for round-tripping in the editor), or `nil` if unset.
  var raw: String? {
    defaults.string(forKey: Self.defaultsKey).trimmedNonEmpty()
  }

  /// The stored terms parsed into a clean list (`KeyTerms.parse`): split on
  /// commas, trimmed, with blanks and duplicates removed (case-insensitively,
  /// keeping first spelling).
  var terms: [String] {
    KeyTerms.parse(raw)
  }
}
