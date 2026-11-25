import AssemblyAI
import BlurtEngine

/// The Words tab's edits, apart from its views: what adding a key term does to
/// the list it joins. Parsing is the engine's (`KeyTermList`), the request's
/// caps the AssemblyAI SDK's (`KeyTerms`). A text shortcut's rule is the
/// engine's too (`TextShortcut.canSave`), shared with the Mac.
package nonisolated enum WordsEdit {
  /// `terms` with whatever `draft` holds added at the end: one term, or several
  /// separated by commas. Duplicates of a term already there drop
  /// case-insensitively, and nothing new is added past the request's term cap,
  /// so a term that couldn't be sent isn't kept either. The terms already
  /// there are never dropped: the keyboard's + and a shared list add without
  /// the cap (`SharedStore.addKeyTerm`), so the list can already be over it,
  /// and an add here must not quietly delete the ones past it.
  package static func addingKeyTerms(_ draft: String, to terms: [String]) -> [String] {
    let room = KeyTerms.termCap - terms.count
    guard room > 0 else {
      return terms
    }
    let known = Set(terms.map { $0.lowercased() })
    let fresh = KeyTermList.parse(draft).filter { !known.contains($0.lowercased()) }
    return terms + fresh.prefix(room)
  }
}
