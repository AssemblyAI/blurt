import Foundation

/// The comma-separated key-term list, as the engine's `KeyTermsStore` reads
/// it: split, trimmed, emptied of blanks, deduplicated case-insensitively in
/// first-seen order.
package nonisolated enum KeyTermList {
  package static func parse(_ raw: String) -> [String] {
    var seen = Set<String>()
    var terms: [String] = []
    for piece in raw.split(separator: ",") {
      let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
      terms.append(term)
    }
    return terms
  }

  package static func join(_ terms: [String]) -> String {
    terms.joined(separator: ", ")
  }
}
