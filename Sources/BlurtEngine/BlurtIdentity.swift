/// The single definition of Blurt's reverse-DNS identity string. Shared by
/// every unified-logging subsystem and derived keys so the documented
/// log-discovery predicates can't drift between components.
public enum BlurtIdentity {
  /// Reverse-DNS identity ("dev.alex.blurt"): the logging subsystem and the
  /// prefix for derived keys/labels. Must match `BUNDLE_ID` in
  /// `scripts/reset-install.sh`, which hard-codes the same value for its
  /// `defaults`/`tccutil` cleanup (bash can't read this constant).
  ///
  /// It is also the **release** bundle id, but is not interchangeable with the
  /// running one: debug builds ship under `dev.alex.blurt.dev` so a dev install
  /// is a separate app to macOS (see `project.yml`). One log subsystem across
  /// both is deliberate — the documented `log show` predicates stay valid
  /// whichever build is running — but anything addressing *this process's*
  /// container, defaults domain or TCC records must read
  /// `Bundle.main.bundleIdentifier` instead.
  public static let subsystem = "dev.alex.blurt"

  /// The Keychain service for the API key item: the plain app name, so the
  /// entry appears as "blurt" in Keychain Access instead of a developer-domain
  /// string. Must match `KEYCHAIN_SERVICE` in `scripts/reset-install.sh`.
  public static let keychainService = "blurt"
}
