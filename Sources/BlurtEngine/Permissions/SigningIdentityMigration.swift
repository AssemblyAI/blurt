/// Decides whether a stale Accessibility TCC grant must be cleared because the
/// signing team changed. macOS keys the Accessibility grant to the app's
/// designated requirement, which pins the signing team (`leaf[subject.OU]`); a
/// team change orphans the grant ("toggle on, still denied") because the stored
/// code requirement still names the old team. Cert rotation *within* a team does
/// not, so the team identifier is the exact boundary to watch.
///
/// Pure and fully injectable: the caller supplies the persisted team, the current
/// team, the live trust state, and the reset side effect.
public enum SigningIdentityMigration {
  public enum Decision: Equatable {
    /// Unsigned/ad-hoc build, or the team is unchanged since last launch.
    case noAction
    /// Team changed but the app is already trusted — nothing stale to clear;
    /// just record the new team so we don't re-evaluate next launch.
    case recordTeam(String)
    /// Team changed and the app is not trusted — a grant pinned to the old team
    /// may be blocking us. Reset it, then record the new team on success.
    case resetThenRecord(String)
  }

  /// `lastTeam == nil` is deliberately treated as "changed": every
  /// currently-shipped build predates this marker, so a missing value means a
  /// possible upgrade, never a known-fresh install. (A genuine fresh install
  /// yields `.resetThenRecord`, where the reset is a harmless no-op.)
  public static func decide(
    lastTeam: String?, currentTeam: String?, isTrusted: Bool
  ) -> Decision {
    guard let currentTeam else { return .noAction }
    guard lastTeam != currentTeam else { return .noAction }
    return isTrusted ? .recordTeam(currentTeam) : .resetThenRecord(currentTeam)
  }

  /// Runs one migration pass. Returns the team to persist, or `nil` to persist
  /// nothing. On a needed reset, persists (returns the team) only if `reset`
  /// succeeds, so a failed reset is retried on the next launch rather than being
  /// masked by a recorded marker.
  public static func run(
    lastTeam: String?, currentTeam: String?, isTrusted: Bool, reset: () -> Bool
  ) -> String? {
    switch decide(lastTeam: lastTeam, currentTeam: currentTeam, isTrusted: isTrusted) {
    case .noAction: return nil
    case .recordTeam(let team): return team
    case .resetThenRecord(let team): return reset() ? team : nil
    }
  }
}
