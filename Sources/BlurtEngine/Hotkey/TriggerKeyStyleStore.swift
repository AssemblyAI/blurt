import Foundation

/// Persists what each trigger key is set to (`TriggerKeyChoice`) — dictate
/// with a style, read the selection aloud, ask about it, or nothing — as set in
/// the Keys tab. Read through `TriggerKeyBindings`, which owns the defaults and
/// the rule that the bound key always dictates; this is the one write.
///
/// Stored as one JSON object, keycode → choice (`TriggerKeyMap`), under its own
/// key so an install that never touches it reads as the defaults. The name and
/// raw key predate read and ask, when every entry was a style id.
public struct TriggerKeyStyleStore {
  /// Public so SwiftUI views can observe it directly (e.g. `@AppStorage`).
  public static var defaultsKey: String { DefaultsKey.triggerKeyStyles.key }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Sets `key`'s choice, keeping the one rule a write can break: the bound key
  /// always dictates. Taking it off dictation first moves the binding to the
  /// next dictating key; with none, nothing is written and this returns false.
  /// A choice equal to the key's default is stored as no entry, so a key set
  /// back to its default leaves nothing behind.
  @discardableResult
  public func setChoice(_ choice: TriggerKeyChoice, for key: TriggerKey) -> Bool {
    let bindings = TriggerKeyBindings(defaults: defaults)
    var bound = bindings.bound
    if key == bound, choice.action != .dictate {
      guard let next = bindings.dictatingKeys.first(where: { $0 != key }) else { return false }
      TriggerKeyStore(defaults: defaults).triggerKey = next
      bound = next
    }
    var entries = TriggerKeyMap.decode(defaults.string(forKey: Self.defaultsKey) ?? "")
    entries[key] = choice == TriggerKeyBindings.defaultChoice(for: key, bound: bound) ? nil : choice.raw
    TriggerKeyMap.write(entries, to: Self.defaultsKey, in: defaults)
    return true
  }
}
