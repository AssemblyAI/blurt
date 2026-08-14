import Foundation

/// Persists the chosen dictation `TriggerBinding` in `UserDefaults`, encoded
/// into the single `Int` slot the store has always used (see `TriggerBinding`
/// for the encoding). Defaults to the right-⌘ modifier when unset or when the
/// stored code isn't one of the curated options.
public struct TriggerKeyStore {
  /// UserDefaults key holding the encoded trigger binding. Public so SwiftUI
  /// views can observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = DefaultsKey.triggerKeyCode.rawValue
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var triggerBinding: TriggerBinding {
    get {
      // Unset reads as 0, which decodes to nothing, so `fromPersisted`'s
      // right-⌘ fallback covers both "never set" and "unknown code".
      TriggerBinding.fromPersisted(defaults.integer(forKey: Self.defaultsKey))
    }
    nonmutating set {
      defaults.set(newValue.persistedValue, forKey: Self.defaultsKey)
    }
  }
}
