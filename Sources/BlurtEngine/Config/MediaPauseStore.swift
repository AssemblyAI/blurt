import Foundation

/// Persists the experimental "pause music while dictating" switch in
/// `UserDefaults`. Off by default; the Settings window's Advanced pane flips it
/// (its Experimental section), so the pause can be trialled before it is
/// everyone's. Developer mode has no say in it. Music bleeding into the
/// microphone is the transcript's problem, not just the listener's.
///
/// Scoped to the players that can be paused *precisely*: `MediaPlayerApp` entries
/// expose `player state`, so a dictation acts only on one that is already playing
/// and resumes only what it paused. Nothing can start unbidden.
///
/// **Browsers are deliberately not covered** — see `MediaPlayerApp` for the three
/// detection routes that were measured and rejected, and for the blind media-key
/// fallback that was built, tested in real use, and removed. Don't add a switch for
/// it back.
///
/// The host reads this at the start of each dictation, so a change applies to the
/// very next one. Same shape as `EnhancedTranscriptsStore` / `DeveloperModeStore`.
public struct MediaPauseStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe it
  /// directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.pauseMedia.key }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// `bool(forKey:)` returns false for a missing key, so unset means off.
  ///
  /// Read-only, like `DeveloperModeStore.isEnabled`: the Settings toggle writes
  /// the slot through `@AppStorage`, so a setter here would have no production
  /// caller.
  public var isEnabled: Bool {
    defaults.bool(forKey: Self.defaultsKey)
  }
}
