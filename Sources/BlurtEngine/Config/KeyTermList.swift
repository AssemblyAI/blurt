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

  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// Whether `terms` already holds `term` — trimmed, and compared the way
  /// `normalized` dedupes, case-insensitively — so "rizz" is already in a list
  /// holding "Rizz". A blank `term` is in no list.
  public static func contains(_ term: String, in terms: [String]) -> Bool {
    guard let wanted = term.trimmedNonEmpty()?.lowercased() else {
      return false
    }
    return terms.contains { $0.lowercased() == wanted }
  }

  // periphery:ignore - public for the iOS app (App/BlurtiOS), which the Mac scan doesn't index.
  /// `terms` with what `draft` holds added at the end: one term, or several
  /// separated by commas (`parse`). Terms already in the list drop
  /// case-insensitively, and nothing new is added once the list holds
  /// `maxCount` — a provider's cap, passed in because fitting to it is the
  /// provider's call. The terms already there are never dropped, even when the
  /// list is over `maxCount` already: an add must not quietly delete the ones
  /// past it.
  public static func appending(_ draft: String, to terms: [String], maxCount: Int = .max) -> [String] {
    let room = maxCount - terms.count
    guard room > 0 else {
      return terms
    }
    let fresh = parse(draft).filter { !contains($0, in: terms) }
    return terms + fresh.prefix(room)
  }
}
