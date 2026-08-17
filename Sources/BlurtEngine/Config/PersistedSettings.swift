import Foundation

/// The "reset to a clean state" sweep over every `UserDefaults` key the engine's
/// settings stores persist — trigger key, sound pack, key terms, developer mode,
/// enhanced transcripts, overlay origin, and the timestamp throttling the automatic
/// update check.
///
/// The keys themselves live in `DefaultsKey`, which each store reads its own key
/// from, so adding a store and adding it to the sweep are not merely the *same*
/// edit — they are the same line. The sweep lives here, next to that enum, rather
/// than as a list in the app shell that goes stale.
public enum PersistedSettings {
  /// Every defaults key an engine store writes — derived from `DefaultsKey`, not
  /// restated here. Nothing to keep in sync: the stores read their keys from that
  /// enum, so a new store's case joins this roster (and therefore `resetAll`) the
  /// moment it exists. This used to be a hand-maintained array, and the
  /// forgotten-half-of-the-edit it warned about happened twice.
  ///
  /// Internal: `resetAll` is the door the shell uses, and the tests read the roster
  /// through `@testable`. Exporting the list as well would invite a caller to walk
  /// it and do its own sweep — which is what `resetAll` replaced — and would trip
  /// periphery's redundant-public check besides.
  static var allDefaultsKeys: [String] { DefaultsKey.allCases.map(\.key) }

  /// Clears every key in the roster, returning the engine's settings to their
  /// unset defaults. The operation lives beside `DefaultsKey` so a reset
  /// that needs more than a defaults removal (a future store with a file or
  /// Keychain half) has one place to grow, and so the sweep itself is covered by
  /// the same suite that pins the roster — the shell that calls it has no tests.
  public static func resetAll(in defaults: UserDefaults = .standard) {
    for key in allDefaultsKeys {
      defaults.removeObject(forKey: key)
    }
  }
}
