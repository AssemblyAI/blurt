/// The roster of `UserDefaults` keys the engine's settings stores persist:
/// trigger key, sound pack, key terms, developer mode, overlay origin, and the
/// timestamp throttling the automatic update check. Owned
/// here — next to the stores — so adding a store and adding it to every "reset
/// to a clean state" sweep (e.g. the app's UI-test launch reset) are the same
/// edit, instead of a hand-maintained list in the app shell that goes stale.
public enum PersistedSettings {
  /// Every defaults key an engine store writes. Keep in sync by adding the new
  /// store's key here in the same change that introduces the store.
  public static let allDefaultsKeys: [String] = [
    TriggerKeyStore.defaultsKey,
    SoundPackStore.defaultsKey,
    KeyTermsStore.defaultsKey,
    DeveloperModeStore.defaultsKey,
    OverlayOriginStore.xDefaultsKey,
    OverlayOriginStore.yDefaultsKey,
    LastUpdateCheckStore.defaultsKey,
  ]
}
