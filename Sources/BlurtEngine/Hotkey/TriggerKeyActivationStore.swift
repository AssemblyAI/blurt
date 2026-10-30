import Foundation

/// Persists whether each trigger key is tapped, held, or either — the Keys
/// tab's second pop-up — as keycode → `TriggerActivation` raw value
/// (`TriggerKeyMap`), the bound key's included. Read through
/// `TriggerKeyBindings`: a key with no entry follows `TriggerActivationStore`'s
/// shared mode (the one setting there was before keys had their own), so an
/// existing install reads unchanged, and moving the binding moves nothing.
public struct TriggerKeyActivationStore {
  /// Public so SwiftUI views can observe it directly (e.g. `@AppStorage`).
  public static var defaultsKey: String { DefaultsKey.triggerKeyActivations.key }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Sets `key`'s mode.
  public func setActivation(_ activation: TriggerActivation, for key: TriggerKey) {
    var entries = TriggerKeyMap.decode(defaults.string(forKey: Self.defaultsKey) ?? "")
    entries[key] = activation.rawValue
    TriggerKeyMap.write(entries, to: Self.defaultsKey, in: defaults)
  }
}
