/// A key-term list's hygiene, the engine's own and the only copy: what a person
/// types becomes clean terms before any provider sees them, for the Mac and
/// iPhone apps alike. Fitting the list to a provider's caps is the provider's
/// job (AssemblyAI's `KeyTerms.fitted`), done on the way out.
public enum KeyTermList {
  /// A comma-separated list as clean terms: split on commas (only commas, so
  /// "San Francisco" stays one term), then `normalized`.
  public static func parse(_ text: String?) -> [String] {
    normalized(text?.split(separator: ",").map(String.init) ?? [])
  }

  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// Terms trimmed, blanks dropped, and duplicates removed case-insensitively,
  /// keeping the first spelling and the user's order. For lists that can't go
  /// through the comma form, such as a contact called "Smith, John".
  public static func normalized(_ terms: [String]) -> [String] {
    var seen = Set<String>()
    return terms.compactMap { $0.trimmedNonEmpty() }.filter { seen.insert($0.lowercased()).inserted }
  }

  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// Terms as the comma-separated text `parse` reads back unchanged.
  public static func join(_ terms: [String]) -> String {
    terms.joined(separator: ", ")
  }
}
