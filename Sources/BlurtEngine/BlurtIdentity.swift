/// The single definition of Blurt's identity strings. Shared by every unified-
/// logging subsystem, the Keychain service, and derived keys so the documented
/// log-discovery predicates can't drift between components.
public enum BlurtIdentity {
  /// Reverse-DNS identity ("dev.alex.blurt"): the bundle id, the logging
  /// subsystem, and the prefix for derived queue labels. Must match
  /// `BUNDLE_ID` in `scripts/reset-install.sh`, which hard-codes the same value
  /// for its `defaults`/`tccutil` cleanup (bash can't read this constant).
  ///
  /// Not the Keychain service — that's `keychainService`.
  public static let subsystem = "dev.alex.blurt"

  /// The Keychain service Blurt's secrets are stored under. Keychain Access
  /// displays this string as the item's *name*, so it is the product name rather
  /// than the reverse-DNS id: someone auditing their keychain should see "Blurt"
  /// — matching the app they installed — not a developer-namespaced string they
  /// have no way to connect to it. Must match `KEYCHAIN_SERVICE` in
  /// `scripts/reset-install.sh`.
  public static let keychainService = "Blurt"

  /// The service Blurt used before `keychainService` existed: it reused
  /// `subsystem`, so the item showed up as "dev.alex.blurt".
  /// `MigratingKeychainStore` adopts and then deletes anything still parked here,
  /// so an existing install keeps its saved key and the old entry stops
  /// cluttering Keychain Access. Must match `LEGACY_KEYCHAIN_SERVICE` in
  /// `scripts/reset-install.sh`.
  public static let legacyKeychainService = subsystem
}
