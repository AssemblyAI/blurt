/// Decides whether a stale Accessibility TCC grant must be cleared because the
/// signing identity changed. macOS keys the Accessibility grant to the app's
/// designated requirement; when what that requirement pins changes, the grant is
/// orphaned ("toggle on, still denied") because the stored code requirement still
/// describes the old binary.
///
/// What counts as the identity depends on how the build is signed, and
/// `SigningIdentity.current()` collapses both cases into one string:
///
/// - Team-signed builds pin `leaf[subject.OU]`, so the identity is the Team ID.
///   Cert rotation *within* a team does not orphan the grant, which is why the
///   team identifier — not the leaf — is the boundary to watch.
/// - Ad-hoc builds (the per-PR dev build) pin the cdhash, so the identity is the
///   cdhash and *every* build is a new one. Without this, a reviewer who installs
///   a second dev build sees Blurt already switched on in System Settings and can
///   never get past the wizard's Accessibility step, because that row belongs to
///   the previous build's signature.
///
/// Pure and fully injectable: the caller supplies the persisted identity, the
/// current identity, the live trust state, and the reset side effect.
public enum SigningIdentityMigration {
  /// `UserDefaults` key holding the signing identity recorded by the last
  /// migration pass — the `lastIdentity` input to `run`. Owned here, next to the
  /// decision it feeds, rather than as a literal at the shell call site.
  ///
  /// Deliberately **absent** from `PersistedSettings.allDefaultsKeys`: that roster
  /// is the "reset to a clean preinstall state" sweep, and this marker is not a
  /// user setting but a record of what the migration has already done. Clearing it
  /// would make every swept launch look like an identity change and re-run the
  /// `tccutil` reset. Renaming it would do the same for every installed user, so
  /// the string is frozen — it predates the ad-hoc case and still says "Team".
  public static let lastSigningIdentityDefaultsKey = "accessibility.lastSigningTeam"

  public enum Decision: Equatable {
    /// Unsigned build, or the identity is unchanged since last launch.
    case noAction
    /// Identity changed but the app is already trusted — nothing stale to clear;
    /// just record the new identity so we don't re-evaluate next launch.
    case record(String)
    /// Identity changed and the app is not trusted — a grant pinned to the old
    /// signature may be blocking us. Reset it, then record on success.
    case resetThenRecord(String)
  }

  /// `lastIdentity == nil` is deliberately treated as "changed": every build that
  /// predates this marker is missing it, so a missing value means a possible
  /// upgrade, never a known-fresh install. (A genuine fresh install yields
  /// `.resetThenRecord`, where the reset is a harmless no-op.)
  public static func decide(
    lastIdentity: String?, currentIdentity: String?, isTrusted: Bool
  ) -> Decision {
    guard let currentIdentity else { return .noAction }
    guard lastIdentity != currentIdentity else { return .noAction }
    return isTrusted ? .record(currentIdentity) : .resetThenRecord(currentIdentity)
  }

  /// Runs one migration pass. Returns the identity to persist, or `nil` to persist
  /// nothing. On a needed reset, persists (returns the identity) only if `reset`
  /// succeeds, so a failed reset is retried on the next launch rather than being
  /// masked by a recorded marker.
  public static func run(
    lastIdentity: String?, currentIdentity: String?, isTrusted: Bool, reset: () -> Bool
  ) -> String? {
    let decision = decide(
      lastIdentity: lastIdentity, currentIdentity: currentIdentity, isTrusted: isTrusted)
    switch decision {
    case .noAction: return nil
    case .record(let identity): return identity
    case .resetThenRecord(let identity): return reset() ? identity : nil
    }
  }
}
