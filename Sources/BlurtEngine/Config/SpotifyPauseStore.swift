import Foundation

/// Persists the "pause Spotify while dictating" switch in `UserDefaults`. Off
/// by default; the Settings window's Dictation section flips it. While on, a
/// dictation that finds Spotify playing pauses it and resumes it when the
/// dictation ends (see `SpotifyPauser`, which reads this per dictation, so a
/// change applies to the very next one). Off, Spotify is never even queried —
/// which keeps macOS's Automation prompt away from users who never opt in.
/// Same shape as `DeveloperModeStore`.
public struct SpotifyPauseStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.pauseSpotify.key }
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
