import Foundation

/// One spoken phrase and the text it expands to — "personal email" →
/// `me@example.com`. Applied to the finished transcript on the machine, after
/// the dictation response and before the paste (see `TextShortcutExpander`);
/// nothing about a shortcut goes on the wire.
///
/// The `id` is minted once so the Settings list and its editor sheet can track
/// a row across a rename of its trigger.
public struct TextShortcut: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public var trigger: String
  public var expansion: String

  public init(trigger: String, expansion: String) {
    self.init(id: UUID(), trigger: trigger, expansion: expansion)
  }

  init(id: UUID, trigger: String, expansion: String) {
    self.id = id
    self.trigger = trigger
    self.expansion = expansion
  }
}

/// Storage for the user's text shortcuts, as one JSON list in `UserDefaults`.
///
/// Has a setter for the same encoded-on-write reason as `StyleProfileStore`:
/// the JSON shape is the store's business, so the Settings sheet writes through
/// here and binds `@AppStorage` to `defaultsKey` only to observe it. The
/// pipeline reads `shortcuts` at every transcript (via the session's
/// `textShortcutsProvider`), so an edit applies to the next dictation.
public struct TextShortcutStore {
  /// `UserDefaults` key holding the JSON-encoded list. A `String` slot so
  /// `@AppStorage` can observe it, as with `StyleProfileStore.defaultsKey`.
  public static var defaultsKey: String { DefaultsKey.textShortcuts.key }

  /// How many shortcuts the user may define — generous, since each costs one
  /// alternation in a regex run once per dictation.
  public static let shortcutLimit = 200

  /// The most `Character`s a trigger may hold. A trigger is a spoken phrase, a
  /// few words at most; the cap keeps a pasted paragraph from becoming one.
  public static let triggerLimit = 60

  /// The most `Character`s an expansion may hold.
  public static let expansionLimit = 2000

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The user's shortcuts, in their own order, normalized on the way out as
  /// well as in so a hand-edited defaults value can't reach the expander raw.
  public var shortcuts: [TextShortcut] {
    get { shortcuts(decoding: defaults.string(forKey: Self.defaultsKey) ?? "") }
    nonmutating set {
      // Spelled failably for the reason on `StyleProfileStore.profiles`:
      // dropping the write beats trapping in a settings sheet.
      guard let data = try? JSONEncoder().encode(Self.normalized(newValue)),
        let json = String(data: data, encoding: .utf8)
      else { return }
      defaults.set(json, forKey: Self.defaultsKey)
    }
  }

  /// The shortcuts behind a raw slot value a SwiftUI view has already observed
  /// — the same decode and normalization the getter uses. Blank or undecodable
  /// reads as no shortcuts.
  public func shortcuts(decoding raw: String) -> [TextShortcut] {
    guard !raw.isEmpty,
      let decoded = try? JSONDecoder().decode([TextShortcut].self, from: Data(raw.utf8))
    else { return [] }
    return Self.normalized(decoded)
  }

  /// The identity two triggers share when the expander can't tell them apart:
  /// letters and digits only, lowercased, with the separators dropped — it
  /// treats any separator run (or none) between words as equal, so "personal
  /// email", "Personal-Email" and "personalemail" are one phrase. Empty for a
  /// trigger with no letters or digits, which can never match anything.
  public static func matchKey(for trigger: String) -> String {
    TextShortcutExpander.words(in: trigger).joined().lowercased()
  }

  /// The one funnel every list passes through, on read and on write: trimmed
  /// fields within their caps, entries with a blank or unmatchable trigger or a
  /// blank expansion dropped, and triggers deduplicated by `matchKey` (first
  /// wins — two expansions for one phrase could only ever apply one of them).
  /// Idempotent.
  static func normalized(_ shortcuts: [TextShortcut]) -> [TextShortcut] {
    var seen = Set<String>()
    var result: [TextShortcut] = []
    for shortcut in shortcuts {
      guard result.count < shortcutLimit,
        let trigger = shortcut.trigger.trimmedNonEmpty().map({ String($0.prefix(triggerLimit)) }),
        let expansion = shortcut.expansion.trimmedNonEmpty().map({
          String($0.prefix(expansionLimit))
        }),
        case let key = matchKey(for: trigger), !key.isEmpty,
        seen.insert(key).inserted
      else { continue }
      result.append(TextShortcut(id: shortcut.id, trigger: trigger, expansion: expansion))
    }
    return result
  }
}
