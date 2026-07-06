import Foundation

/// Persists the developer-mode switch in `UserDefaults`. Off by default; the
/// Settings window's Developer section flips it. While on, each completed
/// dictation is appended to `DictationLog` — that gate is the switch's only
/// effect, so a user who never opts in has no dictation text on disk.
/// Same shape as `TriggerKeyStore` / `SoundPackStore`.
public struct DeveloperModeStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = "BlurtDeveloperMode"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// `bool(forKey:)` returns false for a missing key, so unset means off.
  var isEnabled: Bool {
    get { defaults.bool(forKey: Self.defaultsKey) }
    nonmutating set { defaults.set(newValue, forKey: Self.defaultsKey) }
  }
}
