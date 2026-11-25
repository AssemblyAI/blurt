import AssemblyAI

/// The Words tab's edits, apart from its views: what adding a key term does to
/// the list it joins. The list's own rules — parsing and the request's caps
/// (`KeyTerms`) — are the AssemblyAI SDK's. A text shortcut's rule is the
/// engine's (`TextShortcut.canSave`), shared with the Mac.
package nonisolated enum WordsEdit {
  /// `terms` with whatever `draft` holds added at the end: one term, or several
  /// separated by commas. Duplicates of a term already there drop
  /// case-insensitively, and the list stops at the request's term cap, so a
  /// term that couldn't be sent isn't kept either.
  package static func addingKeyTerms(_ draft: String, to terms: [String]) -> [String] {
    Array(KeyTerms.normalized(terms + KeyTerms.parse(draft)).prefix(KeyTerms.termCap))
  }
}
