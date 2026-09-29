import Testing

@testable import BlurtEngine

/// Whether a launch shows the What's New sheet, and what it records. The shell
/// that applies this has no test target, and every way to get it wrong is quiet:
/// a sheet that never appears, one that greets a brand-new user, or one that
/// comes back on every launch.
@Suite("WhatsNewLaunch")
struct WhatsNewLaunchTests {
  private static let changelog = Changelog(
    markdown: """
      ## 0.1.59 — 2026-10-13
      ### Fixes
      - fifty-nine
      ## 0.1.58 — 2026-10-06
      ### Fixes
      - fifty-eight
      ## 0.1.57 — 2026-09-29
      ### Fixes
      - fifty-seven
      """)

  private func version(_ string: String) throws -> SemanticVersion {
    try #require(SemanticVersion(string))
  }

  private func decide(
    current: String, lastSeen: String?, isConfigured: Bool = true, hasRunBefore: Bool = true
  ) throws -> WhatsNewLaunch {
    try Self.changelog.whatsNewAtLaunch(
      current: version(current), lastSeen: lastSeen.map { try version($0) }, isConfigured: isConfigured,
      hasRunBefore: hasRunBefore)
  }

  private func shownVersions(_ decision: WhatsNewLaunch) -> [String] {
    decision.entries.map(\.version.description)
  }

  @Test("an update shows every entry since the last version seen, newest first, then records")
  func upgradeShowsTheRange() throws {
    let decision = try decide(current: "0.1.59", lastSeen: "0.1.57")
    #expect(shownVersions(decision) == ["0.1.59", "0.1.58"])
    #expect(decision.recordsCurrentVersion)

    let oneStep = try decide(current: "0.1.58", lastSeen: "0.1.57")
    #expect(shownVersions(oneStep) == ["0.1.58"])
  }

  @Test("an update to a build with no entry in range shows nothing but still records")
  func upgradeWithoutAnEntry() throws {
    let decision = try decide(current: "0.1.60", lastSeen: "0.1.59")
    #expect(decision.entries.isEmpty)
    #expect(decision.recordsCurrentVersion)
  }

  @Test("the same version as last time, or an older one, does nothing")
  func relaunchAndDowngrade() throws {
    let relaunch = try decide(current: "0.1.58", lastSeen: "0.1.58")
    #expect(relaunch == WhatsNewLaunch(entries: [], recordsCurrentVersion: false))
    // Recording the downgrade would replay 0.1.59's notes on the way back up.
    let downgrade = try decide(current: "0.1.58", lastSeen: "0.1.59")
    #expect(downgrade == WhatsNewLaunch(entries: [], recordsCurrentVersion: false))
  }

  @Test("a fresh install's first run records its version and shows nothing")
  func freshInstall() throws {
    // A first run is never configured and has never checked for updates.
    let decision = try decide(current: "0.1.58", lastSeen: nil, isConfigured: false, hasRunBefore: false)
    #expect(decision == WhatsNewLaunch(entries: [], recordsCurrentVersion: true))
    // So its next launch, now set up, is an ordinary relaunch.
    let next = try decide(current: "0.1.58", lastSeen: "0.1.58")
    #expect(next.entries.isEmpty)
  }

  @Test("an update whose launch finds setup unfinished waits for a configured launch")
  func unconfiguredUpgradeWaits() throws {
    let decision = try decide(current: "0.1.59", lastSeen: "0.1.57", isConfigured: false)
    #expect(decision == WhatsNewLaunch(entries: [], recordsCurrentVersion: false))
    // An install from before this feature, likewise: no baseline recorded yet.
    let untracked = try decide(current: "0.1.59", lastSeen: nil, isConfigured: false, hasRunBefore: true)
    #expect(untracked == WhatsNewLaunch(entries: [], recordsCurrentVersion: false))
  }

  @Test("an install from before this feature shows this version's notes once")
  func untrackedUpgrade() throws {
    let decision = try decide(current: "0.1.58", lastSeen: nil)
    #expect(shownVersions(decision) == ["0.1.58"])
    #expect(decision.recordsCurrentVersion)
    // A build with no entry of its own falls back to the newest one before it.
    let noEntry = try decide(current: "0.1.60", lastSeen: nil)
    #expect(shownVersions(noEntry) == ["0.1.59"])
  }

  @Test("a configured launch with nothing stored and no sign of an earlier run just records")
  func configuredWithoutHistory() throws {
    // A reinstall that inherited its key and permissions, or a UI-test launch
    // (which resets the defaults but forces the ready state).
    let decision = try decide(current: "0.1.58", lastSeen: nil, hasRunBefore: false)
    #expect(decision == WhatsNewLaunch(entries: [], recordsCurrentVersion: true))
  }
}
