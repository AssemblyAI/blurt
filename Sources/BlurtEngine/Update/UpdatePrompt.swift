import Foundation

/// The asset-name parsing and wording behind the self-update prompt. Pure
/// string logic, owned in the engine so the release pipeline's asset-naming
/// convention (`Blurt-<version>.dmg`, published by `scripts/release-publish.sh`
/// and matched by AppUpdater's `<repo>-<tag>` rule) is pinned by unit tests —
/// the AppKit `AutoUpdater` just renders these strings into its alert.
public enum UpdatePrompt {
  /// Parses the version out of a `Blurt-<version>.dmg` asset name: the part
  /// after the last hyphen, sans extension. Returns nil when the name doesn't
  /// fit the convention (no hyphen, or nothing after it) so the prompt drops
  /// its version line rather than presenting a non-version as one.
  public static func version(fromAssetNamed name: String) -> String? {
    let stem = (name as NSString).deletingPathExtension
    let parts = stem.split(separator: "-")
    guard parts.count >= 2, let version = parts.last else { return nil }
    return String(version)
  }

  /// "Blurt X is now available—you have Y. Would you like to install it now?…"
  /// Degrades gracefully: without a current version it drops the "you have"
  /// clause, and without a new version it drops the version line entirely.
  public static func message(newVersion: String?, currentVersion: String?) -> String {
    let lead: String
    switch (newVersion, currentVersion) {
    case let (new?, current?): lead = "Blurt \(new) is now available—you have \(current). "
    case let (new?, nil): lead = "Blurt \(new) is now available. "
    default: lead = ""
    }
    return lead + "Would you like to install it now? Blurt will quit and reopen to finish."
  }
}
