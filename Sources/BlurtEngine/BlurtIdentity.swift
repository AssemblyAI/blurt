/// The single definition of Blurt's reverse-DNS identity string. Shared by
/// every unified-logging subsystem and derived keys so the documented
/// log-discovery predicates can't drift between components.
public enum BlurtIdentity {
  /// Reverse-DNS identity ("dev.alex.blurt"): the logging subsystem and the
  /// prefix for derived keys/labels. Must match `BUNDLE_ID` in
  /// `scripts/reset-install.sh`, which hard-codes the same value for its
  /// `defaults`/`tccutil` cleanup (bash can't read this constant).
  public static let subsystem = "dev.alex.blurt"

  /// The Keychain service for the API key item: the plain app name, so the
  /// entry appears as "blurt" in Keychain Access instead of a developer-domain
  /// string. Must match `KEYCHAIN_SERVICE` in `scripts/reset-install.sh`.
  public static let keychainService = "blurt"

  /// The Keychain service the API key lived under before the rename to
  /// `keychainService` (it reused `subsystem`). Only `APIKeyStore`'s one-shot
  /// migration and `scripts/reset-install.sh` still reference it. Must match
  /// `LEGACY_KEYCHAIN_SERVICE` in that script.
  public static let legacyKeychainService = "dev.alex.blurt"
}
