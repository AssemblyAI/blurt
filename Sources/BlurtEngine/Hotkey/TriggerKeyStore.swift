import Foundation

/// Persists the chosen dictation `TriggerKey` as its keycode in `UserDefaults`.
/// Defaults to right ⌘ when unset or when the stored code isn't one of the
/// curated options.
public struct TriggerKeyStore {
  /// UserDefaults key holding the trigger keycode. Public so SwiftUI views can
  /// observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = "BlurtTriggerKeyCode"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var triggerKey: TriggerKey {
    get {
      let code = defaults.object(forKey: Self.defaultsKey) as? Int
      return code.map(TriggerKey.fromPersisted) ?? .rightCommand
    }
    nonmutating set {
      defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
    }
  }
}
