import Foundation

/// Persists the developer-mode switch in `UserDefaults`. Off by default; the
/// Settings window's Developer section flips it. While on, each completed
/// dictation, each failure, and each Custom-capture input event is appended to
/// its `DictationLog` file — those gates are the switch's only effect, so a
/// user who never opts in has nothing on disk.
/// Same shape as `TriggerKeyStore` / `SoundPackStore`.
public struct DeveloperModeStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static let defaultsKey = DefaultsKey.developerMode.rawValue
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// `bool(forKey:)` returns false for a missing key, so unset means off.
  ///
  /// Read-only: the Settings toggle writes the slot directly through `@AppStorage`
  /// (that's what `defaultsKey` is public for), so a setter here had no production
  /// caller — only tests, which is the hazard `HotkeyStepView` documents in the
  /// other direction. Rather than leave a write path nothing exercised, there is
  /// none; seed the slot to change the switch.
  var isEnabled: Bool {
    defaults.bool(forKey: Self.defaultsKey)
  }
}
