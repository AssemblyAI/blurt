import Testing

@testable import BlurtEngine

@Suite struct SigningIdentityMigrationTests {
  private typealias Migration = SigningIdentityMigration

  // The identities `SigningIdentity.current(includingAdHoc:)` produces, one per
  // way Blurt is signed. The migration treats them alike — it only ever compares
  // strings — but which pairs of them differ is the whole reason the cases below
  // exist, so they are spelled out rather than left implied.
  //
  // `release` and `devBuild` share a team and still differ: a release carries
  // codesign's default Developer ID requirement (leaf CN + marker OIDs), while the
  // `project.yml` post-build install stamps an explicit team-based one.
  private static let prefix = SigningIdentity.requirementPrefix
  private static let anchor = "identifier \"dev.alex.blurt\" and anchor apple generic"
  private static let devBuild = "\(prefix)\(anchor) and certificate leaf[subject.OU] = \"B2VQF7Q2QY\""
  private static let release = "\(prefix)\(anchor) and certificate leaf[subject.CN] = \"Developer ID\""
  private static let adHoc = "\(prefix)cdhash H\"\(String(repeating: "ab", count: 20))\""
  private static let nextAdHoc = "\(prefix)cdhash H\"\(String(repeating: "cd", count: 20))\""

  // decide(): unsigned builds never act.
  @Test func unsignedNeverActs() {
    #expect(Migration.decide(lastIdentity: nil, currentIdentity: nil, isTrusted: false) == .noAction)
    #expect(Migration.decide(lastIdentity: "OLD", currentIdentity: nil, isTrusted: true) == .noAction)
  }

  // decide(): same identity as last launch is steady state, regardless of trust.
  @Test func steadyStateIsNoAction() {
    #expect(Migration.decide(lastIdentity: "NEW", currentIdentity: "NEW", isTrusted: false) == .noAction)
    #expect(Migration.decide(lastIdentity: "NEW", currentIdentity: "NEW", isTrusted: true) == .noAction)
  }

  // decide(): no marker (every build predating it) is treated as changed.
  @Test func firstSeenUntrustedResets() {
    let decision = Migration.decide(lastIdentity: nil, currentIdentity: "NEW", isTrusted: false)
    #expect(decision == .resetThenRecord("NEW"))
  }
  @Test func firstSeenTrustedRecordsOnly() {
    let decision = Migration.decide(lastIdentity: nil, currentIdentity: "NEW", isTrusted: true)
    #expect(decision == .record("NEW"))
  }

  // decide(): an actual team change.
  @Test func teamChangedUntrustedResets() {
    let decision = Migration.decide(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: false)
    #expect(decision == .resetThenRecord("NEW"))
  }
  @Test func teamChangedTrustedRecordsOnly() {
    let decision = Migration.decide(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: true)
    #expect(decision == .record("NEW"))
  }

  // decide(): the per-PR dev build. Every ad-hoc build carries a fresh cdhash, so
  // a grant taken by the previous one is pinned to a requirement this binary can
  // never satisfy — reset it rather than leaving the reviewer stuck in front of a
  // Blurt row that is switched on and still denied.
  @Test func adHocRebuildUntrustedResets() {
    let decision = Migration.decide(
      lastIdentity: Self.adHoc, currentIdentity: Self.nextAdHoc, isTrusted: false)
    #expect(decision == .resetThenRecord(Self.nextAdHoc))
  }

  // decide(): relaunching the *same* dev build must not disturb a working grant.
  @Test func sameAdHocBuildIsNoAction() {
    let trusted = Migration.decide(
      lastIdentity: Self.adHoc, currentIdentity: Self.adHoc, isTrusted: true)
    let untrusted = Migration.decide(
      lastIdentity: Self.adHoc, currentIdentity: Self.adHoc, isTrusted: false)
    #expect(trusted == .noAction)
    #expect(untrusted == .noAction)
  }

  // decide(): swapping between a release install and the per-PR artifact, in both
  // directions — what a reviewer does when they drop the artifact over
  // /Applications/Blurt.app and then put the release DMG back.
  @Test func swappingBetweenReleaseAndDevBuildResets() {
    let toDevBuild = Migration.decide(
      lastIdentity: Self.release, currentIdentity: Self.adHoc, isTrusted: false)
    let backToRelease = Migration.decide(
      lastIdentity: Self.adHoc, currentIdentity: Self.release, isTrusted: false)
    #expect(toDevBuild == .resetThenRecord(Self.adHoc))
    #expect(backToRelease == .resetThenRecord(Self.release))
  }

  // decide(): the regression this whole file exists for. `scripts/dev-build.sh`
  // over a release install keeps the bundle id, the install path AND the signing
  // team — only the designated requirement moves (default Developer ID → explicit
  // team-based). While the recorded identity was the Team ID this read as steady
  // state, so nothing reset the grant TCC had pinned to the release's
  // requirement: the Blurt row stayed switched on, `AXIsProcessTrusted()` kept
  // returning false, and the wizard's Accessibility step could not be passed.
  @Test func installingALocalDevBuildOverAReleaseResets() {
    let toDevBuild = Migration.decide(
      lastIdentity: Self.release, currentIdentity: Self.devBuild, isTrusted: false)
    let backToRelease = Migration.decide(
      lastIdentity: Self.devBuild, currentIdentity: Self.release, isTrusted: false)
    #expect(toDevBuild == .resetThenRecord(Self.devBuild))
    #expect(backToRelease == .resetThenRecord(Self.release))
  }

  // decide(): …and the flip side — the identity must still be *stable* for the
  // loop that rebuilds the same way over and over. Two `dev-build.sh` runs pin the
  // same team-based requirement, so a working grant survives a rebuild; nothing
  // here may reset on every launch.
  @Test func rebuildingTheSameWayIsNoAction() {
    #expect(
      Migration.decide(lastIdentity: Self.devBuild, currentIdentity: Self.devBuild, isTrusted: true)
        == .noAction)
    #expect(
      Migration.decide(lastIdentity: Self.release, currentIdentity: Self.release, isTrusted: false)
        == .noAction)
  }

  // run(): steady state / unsigned persist nothing and never reset.
  @Test func runNoActionPersistsNothingAndSkipsReset() {
    let out = Migration.run(lastIdentity: "NEW", currentIdentity: "NEW", isTrusted: false) {
      Issue.record("reset must not run for .noAction")
      return true
    }
    #expect(out == nil)
  }

  // run(): a trusted identity change records without resetting.
  @Test func runRecordsWithoutResetting() {
    var didReset = false
    let out = Migration.run(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: true) {
      didReset = true
      return true
    }
    #expect(out == "NEW")
    #expect(didReset == false)
  }

  // run(): an untrusted identity change resets, then persists only on success.
  @Test func runResetsThenPersistsOnSuccess() {
    let out = Migration.run(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: false) { true }
    #expect(out == "NEW")
  }
  @Test func runDoesNotPersistWhenResetFails() {
    let out = Migration.run(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: false) { false }
    #expect(out == nil)
  }
}
