public import Foundation

/// Persists the microphone selection in `UserDefaults` as the pinned device's
/// UID string, empty (or unset) meaning "same as system". Same shape as
/// `TriggerKeyStore`; lives in the engine so its key is a `DefaultsKey` case and
/// the setting joins `PersistedSettings.resetAll`'s sweep by construction.
public struct MicDeviceStore {
  /// UserDefaults key holding the pinned device UID. Public so SwiftUI views
  /// can observe it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.micDeviceUID.key }

  private let defaults: UserDefaults

  /// The microphone dictation records from: the pinned device, or "same as
  /// system" when none is pinned.
  public var selection: MicDeviceSelection {
    get {
      MicDeviceSelection.fromPersisted(defaults.string(forKey: Self.defaultsKey) ?? "")
    }
    nonmutating set {
      defaults.set(newValue.persistedValue, forKey: Self.defaultsKey)
    }
  }

  /// A store over `defaults`; tests pass an isolated suite.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }
}
