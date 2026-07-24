import Foundation

/// Storage for the user's dictation "key terms" — a comma-separated list of
/// domain words (names, jargon, product names) that get folded into the dictation
/// request `prompt` as vocabulary priming, so the model is more likely to spell
/// them correctly (see `TranscriptionPrompt.build`).
///
/// Unlike the API key these aren't secret, so they live in `UserDefaults` rather
/// than the Keychain. The setup wizard and the Settings window read/write the
/// raw string via `get`/`set`; the transcription pipeline reads the parsed list
/// via `terms()`.
public enum KeyTermsStore {
  /// `UserDefaults` key for the raw, comma-separated string the user typed.
  /// Public so the app can clear it when resetting to a clean state under UI
  /// testing (matching `TriggerKeyStore`/`SoundPackStore`).
  public static let defaultsKey = "BlurtKeyTerms"

  private static var defaults: UserDefaults { .standard }

  /// The raw comma-separated string exactly as the user entered it (preserving
  /// their spacing/order for round-tripping in the editor), or `nil` if unset.
  public static func get() -> String? {
    defaults.string(forKey: defaultsKey).trimmedNonEmpty()
  }

  /// Stores the raw string. Passing `nil` or a blank string clears it.
  public static func set(_ raw: String?) {
    if let trimmed = raw.trimmedNonEmpty() {
      defaults.set(trimmed, forKey: defaultsKey)
    } else {
      defaults.removeObject(forKey: defaultsKey)
    }
  }

  /// The stored terms parsed into a clean list: split on commas, trimmed, with
  /// blanks and duplicates removed (case-insensitively, keeping first spelling).
  public static func terms() -> [String] {
    parse(get())
  }

  /// Pure parse of a comma-separated string into a clean term list. Exposed so
  /// `TranscriptionPrompt` and tests can reuse the exact same rules.
  public static func parse(_ raw: String?) -> [String] {
    guard let raw else { return [] }
    var seen = Set<String>()
    var result: [String] = []
    for piece in raw.split(separator: ",") {
      guard let term = String(piece).trimmedNonEmpty() else { continue }
      let key = term.lowercased()
      guard seen.insert(key).inserted else { continue }
      result.append(term)
    }
    return result
  }
}
