import Foundation

/// Storage for the user's dictation "key terms" — a comma-separated list of
/// domain words (names, jargon, product names) sent as the dictation request's
/// `keyterms_prompt` vocabulary list, so the model is more likely to spell
/// them correctly (see `TranscriptionSteering.build`).
///
/// Unlike the API key these aren't secret, so they live in `UserDefaults` rather
/// than the Keychain. The transcription pipeline reads the parsed list via
/// `terms()`; the editor reads the raw string via `get()`.
///
/// Read-only by design: the Settings field binds `@AppStorage` straight to
/// `defaultsKey`, which is the sole writer. There is deliberately no setter —
/// normalizing on write fought the text field, because the trimmed value was
/// pushed back into the binding as an external change and a trailing space was
/// deleted as the user typed it. Normalization lives on the read side instead
/// (`get()` trims, `parse` trims and dedupes), so a blank field still reads back
/// as "no terms". See the note on `KeyTermsStepView.text`.
public enum KeyTermsStore {
  /// `UserDefaults` key for the raw, comma-separated string the user typed.
  /// Public so the app can clear it when resetting to a clean state under UI
  /// testing (matching `TriggerKeyStore`/`SoundPackStore`).
  public static let defaultsKey = "BlurtKeyTerms"

  private static var defaults: UserDefaults { .standard }

  /// The raw comma-separated string exactly as the user entered it (preserving
  /// their spacing/order for round-tripping in the editor), or `nil` if unset.
  public static var raw: String? {
    defaults.string(forKey: defaultsKey).trimmedNonEmpty()
  }

  /// The stored terms parsed into a clean list: split on commas, trimmed, with
  /// blanks and duplicates removed (case-insensitively, keeping first spelling).
  public static var terms: [String] {
    parse(raw)
  }

  /// Pure parse of a comma-separated string into a clean term list. Exposed so
  /// `TranscriptionSteering` and tests can reuse the exact same rules.
  public static func parse(_ text: String?) -> [String] {
    guard let text else { return [] }
    var seen = Set<String>()
    var result: [String] = []
    for piece in text.split(separator: ",") {
      guard let term = String(piece).trimmedNonEmpty() else { continue }
      let key = term.lowercased()
      guard seen.insert(key).inserted else { continue }
      result.append(term)
    }
    return result
  }
}
