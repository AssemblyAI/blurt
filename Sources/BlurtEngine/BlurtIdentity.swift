/// The single definition of Blurt's reverse-DNS identity string. Shared by
/// every unified-logging subsystem, the Keychain service, and derived keys so
/// the documented log-discovery predicates can't drift between components.
public enum BlurtIdentity {
  /// Reverse-DNS identity ("dev.alex.blurt"): the logging subsystem, the
  /// Keychain service, and the prefix for derived keys/labels. Must match
  /// `BUNDLE_ID`/`KEYCHAIN_SERVICE` in `scripts/reset-install.sh`, which
  /// hard-codes the same value for its `defaults`/`security` cleanup (bash
  /// can't read this constant).
  public static let subsystem = "dev.alex.blurt"
}
