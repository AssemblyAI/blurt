import Foundation

/// The one tap/hold mode every trigger key is pressed under, as set on the
/// Keys tab. Read through `TriggerKeyBindings`, which decodes it with
/// `TriggerActivation.fromPersisted` (unset or unknown is tap-or-hold); this
/// is the one write.
public struct TriggerActivationStore {
  /// UserDefaults key holding the mode. Public so SwiftUI views can observe it
  /// directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.triggerActivation.key }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func setActivation(_ activation: TriggerActivation) {
    defaults.set(activation.rawValue, forKey: Self.defaultsKey)
  }
}
