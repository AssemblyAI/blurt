public import Foundation

/// One spoken phrase and the text it expands to — "personal email" →
/// `me@example.com`. Applied to the finished transcript on the device, after
/// the dictation response and before the text is inserted
/// (`TextShortcutExpander`); nothing about a shortcut goes on the wire.
///
/// The `id` is minted once so a list and its editor can track a row across a
/// rename of its trigger.
public struct TextShortcut: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public var trigger: String
  public var expansion: String

  public init(trigger: String, expansion: String) {
    self.init(id: UUID(), trigger: trigger, expansion: expansion)
  }

  public init(id: UUID, trigger: String, expansion: String) {
    self.id = id
    self.trigger = trigger
    self.expansion = expansion
  }

  /// The identity two triggers share when the expander can't tell them apart:
  /// letters and digits only, lowercased, with the separators dropped — it
  /// treats any separator run (or none) between words as equal, so "personal
  /// email", "Personal-Email" and "personalemail" are one phrase. Empty for a
  /// trigger with no letters or digits, which can never match anything. A list
  /// should hold one shortcut per key: two expansions for one phrase could
  /// only ever apply one of them.
  public static func matchKey(for trigger: String) -> String {
    TextShortcutExpander.words(in: trigger).joined().lowercased()
  }

  /// Whether `trigger` is a phrase one of `otherKeys` (other shortcuts'
  /// `matchKey`s) already holds. Both apps refuse such a phrase, and say so,
  /// rather than let the store's one-per-key rule drop a shortcut unseen.
  public static func isTaken(_ trigger: String, by otherKeys: Set<String>) -> Bool {
    let key = matchKey(for: trigger)
    return !key.isEmpty && otherKeys.contains(key)
  }

  /// Whether a shortcut from these fields can be saved next to shortcuts whose
  /// match keys are `otherKeys`: a phrase with a letter or digit in it that no
  /// other shortcut holds, and a replacement that isn't blank. The one rule
  /// behind the Mac's editor sheet and the iPhone's add form.
  public static func canSave(trigger: String, expansion: String, otherKeys: Set<String>) -> Bool {
    !matchKey(for: trigger).isEmpty && !isTaken(trigger, by: otherKeys) && expansion.trimmedNonEmpty() != nil
  }
}
