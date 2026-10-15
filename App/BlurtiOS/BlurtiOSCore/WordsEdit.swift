import AssemblyAI
import Foundation

/// The Words tab's edits, apart from its views: what adding a key term or a
/// text shortcut does to the list it joins. The lists' own rules — parsing and
/// the request's caps (`KeyTerms`), a shortcut's match key (`TextShortcut`) —
/// are the AssemblyAI SDK's; the stores' limits are the engine's.
package nonisolated enum WordsEdit {
  /// `terms` with whatever `draft` holds added at the end: one term, or several
  /// separated by commas. Duplicates of a term already there drop
  /// case-insensitively, and the list stops at the request's term cap, so a
  /// term that couldn't be sent isn't kept either.
  package static func addingKeyTerms(_ draft: String, to terms: [String]) -> [String] {
    Array(KeyTerms.parse(KeyTerms.join(terms + KeyTerms.parse(draft))).prefix(KeyTerms.termCap))
  }

  /// Whether a shortcut from these fields could be saved: a phrase with a
  /// letter or digit in it, and a replacement that isn't blank.
  package static func canAddShortcut(trigger: String, expansion: String) -> Bool {
    !TextShortcut.matchKey(for: trigger).isEmpty
      && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// `shortcuts` with a new one at the top. A phrase already there — by match
  /// key, so "my email" and "My-Email" are one — gets the new replacement
  /// rather than a second entry the expander could never apply.
  package static func addingShortcut(trigger: String, expansion: String, to shortcuts: [TextShortcut])
    -> [TextShortcut]
  {
    let key = TextShortcut.matchKey(for: trigger)
    return [TextShortcut(trigger: trigger, expansion: expansion)]
      + shortcuts.filter { TextShortcut.matchKey(for: $0.trigger) != key }
  }
}
