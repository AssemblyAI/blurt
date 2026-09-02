import Foundation

/// Persists the "pause music while dictating" switch in `UserDefaults`. Off
/// by default; the Settings window's Dictation section flips it. While on, a
/// dictation that finds a player (Spotify or Apple Music) playing pauses it and
/// resumes it when the dictation ends (see `MediaPauser`, which reads this per
/// dictation, so a change applies to the very next one). Off, no player is ever
/// even queried — which keeps macOS's Automation prompts away from users who
/// never opt in. Same shape as `DeveloperModeStore`.
public struct MediaPauseStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.pauseMedia.key }
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// `bool(forKey:)` returns false for a missing key, so unset means off.
  ///
  /// Read-only for the same reason as `DeveloperModeStore.isEnabled`: the
  /// Settings toggle writes the slot directly through `@AppStorage`, so a
  /// setter here would have no production caller. Seed the slot to change the
  /// switch.
  var isEnabled: Bool {
    defaults.bool(forKey: Self.defaultsKey)
  }
}
