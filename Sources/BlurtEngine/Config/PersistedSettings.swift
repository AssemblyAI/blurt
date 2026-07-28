import Foundation

/// The roster of `UserDefaults` keys the engine's settings stores persist:
/// trigger key, sound pack, key terms, developer mode, overlay origin, and the
/// timestamp throttling the automatic update check. Owned
/// here — next to the stores — so adding a store and adding it to every "reset
/// to a clean state" sweep (e.g. the app's UI-test launch reset) are the same
/// edit, instead of a hand-maintained list in the app shell that goes stale.
public enum PersistedSettings {
  /// Every defaults key an engine store writes. Keep in sync by adding the new
  /// store's key here in the same change that introduces the store.
  ///
  /// Internal: `resetAll` is the door the shell uses, and the tests read the roster
  /// through `@testable`. Exporting the list as well would invite a caller to walk
  /// it and do its own sweep — which is what `resetAll` replaced — and would trip
  /// periphery's redundant-public check besides.
  static let allDefaultsKeys: [String] = [
    TriggerKeyStore.defaultsKey,
    SoundPackStore.defaultsKey,
    KeyTermsStore.defaultsKey,
    DeveloperModeStore.defaultsKey,
    OverlayOriginStore.xDefaultsKey,
    OverlayOriginStore.yDefaultsKey,
    LastUpdateCheckStore.defaultsKey,
  ]

  /// Clears every key in the roster, returning the engine's settings to their
  /// unset defaults. The operation lives next to the list it walks so a reset
  /// that needs more than a defaults removal (a future store with a file or
  /// Keychain half) has one place to grow, and so the sweep itself is covered by
  /// the same suite that pins the roster — the shell that calls it has no tests.
  public static func resetAll(in defaults: UserDefaults = .standard) {
    for key in allDefaultsKeys {
      defaults.removeObject(forKey: key)
    }
  }
}
