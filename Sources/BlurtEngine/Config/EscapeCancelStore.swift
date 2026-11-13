import Foundation

/// Persists the experimental "Escape cancels a dictation" switch in
/// `UserDefaults`. Off by default; the Settings window's Advanced pane flips it
/// (its Experimental section), so the gesture can be trialled before it is
/// everyone's. Developer mode has no say in it. `DictationKeyTap` reads it at each
/// Escape, so a change applies to the next keystroke.
/// Same shape as `DeveloperModeStore`.
public struct EscapeCancelStore {
  /// UserDefaults key holding the switch. Public so SwiftUI views can observe
  /// it directly (e.g. `@AppStorage`) and re-render on change.
  public static var defaultsKey: String { DefaultsKey.escapeCancelsDictation.key }
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// `bool(forKey:)` returns false for a missing key, so unset means off.
  ///
  /// Read-only: the Settings toggle writes the slot through `@AppStorage`, so a
  /// setter here would have no production caller.
  public var isEnabled: Bool {
    defaults.bool(forKey: Self.defaultsKey)
  }
}
