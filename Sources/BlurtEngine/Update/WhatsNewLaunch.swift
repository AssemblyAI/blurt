/// What a launch does about the What's New sheet: which release notes to show,
/// and whether to record the running version as seen (`LastSeenVersionStore`).
///
/// Engine-side for the `AutomaticUpdateCheck` reason: it is a rule, and the
/// shell that applies it has no test target. Decided by
/// `Changelog.whatsNewAtLaunch(current:lastSeen:isConfigured:hasRunBefore:)`.
public struct WhatsNewLaunch: Equatable, Sendable {
  /// The notes to show, newest first. Empty means no sheet.
  public let entries: [ChangelogEntry]
  /// Whether to store the running version as the last one seen.
  public let recordsCurrentVersion: Bool
}

extension Changelog {
  /// The launch decision, given the running version and the last one the user saw.
  ///
  /// - The same version as last time, or an older one (a downgrade), does nothing:
  ///   the notes have been seen, and a downgrade recorded now would replay them.
  /// - Setup unfinished shows nothing, for the reason the update check waits
  ///   (no sheet thrown over the wizard). It still records a **fresh install**'s
  ///   version — which is what keeps a first run from ever reading as an
  ///   upgrade — but otherwise leaves the stored version alone, so an upgrade
  ///   whose launch finds setup broken (a revoked permission) shows its notes
  ///   once setup is back.
  /// - Upgraded: every entry newer than the last version seen, up to and including
  ///   this one. None in that range (a build with no entry of its own) shows
  ///   nothing but still records.
  /// - Nothing stored on a configured launch means the install predates this
  ///   feature, or is a fresh one: every launch of a build that has it records a
  ///   version, and a first run is never configured. `hasRunBefore` tells them
  ///   apart — the shell passes whether an update check has ever completed, which
  ///   a configured Blurt does within a day of its first launch. An upgrade then
  ///   shows this version's notes (there is no telling which version it came
  ///   from); anything else just records.
  public func whatsNewAtLaunch(
    current: SemanticVersion, lastSeen: SemanticVersion?, isConfigured: Bool, hasRunBefore: Bool
  ) -> WhatsNewLaunch {
    if let lastSeen, lastSeen >= current {
      return WhatsNewLaunch(entries: [], recordsCurrentVersion: false)
    }
    guard isConfigured else {
      return WhatsNewLaunch(entries: [], recordsCurrentVersion: lastSeen == nil && !hasRunBefore)
    }
    guard let lastSeen else {
      guard hasRunBefore, let latest = entry(for: current) else {
        return WhatsNewLaunch(entries: [], recordsCurrentVersion: true)
      }
      return WhatsNewLaunch(entries: [latest], recordsCurrentVersion: true)
    }
    return WhatsNewLaunch(
      entries: entries.filter { $0.version > lastSeen && $0.version <= current },
      recordsCurrentVersion: true)
  }
}
