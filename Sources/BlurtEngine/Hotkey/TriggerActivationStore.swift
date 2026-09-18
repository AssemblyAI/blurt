import Foundation

/// Persists the chosen `TriggerActivation` as its raw value in `UserDefaults`.
/// Defaults to tap-or-hold (the shipped behavior) when unset or when the stored
/// value isn't one of the known modes.
public struct TriggerActivationStore {
  /// UserDefaults key holding the activation mode. Public so SwiftUI views can
  /// observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.triggerActivation.key }
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var activation: TriggerActivation {
    get {
      // Unset reads as nil → "", which isn't a known raw value, so
      // `fromPersisted`'s tap-or-hold fallback covers both "never set" and
      // "unknown value".
      TriggerActivation.fromPersisted(defaults.string(forKey: Self.defaultsKey) ?? "")
    }
    nonmutating set {
      defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
    }
  }
}
