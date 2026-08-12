import Testing

@testable import BlurtEngine

@Suite struct SigningIdentityMigrationTests {
  private typealias Migration = SigningIdentityMigration

  // The two identity shapes `SigningIdentity.current()` produces. The migration
  // treats them alike — it only ever compares strings — but the ad-hoc one is the
  // whole reason the cases below exist, so it is spelled out rather than implied.
  private static let team = "B2VQF7Q2QY"
  private static let adHoc = SigningIdentity.cdhashPrefix + String(repeating: "ab", count: 20)
  private static let nextAdHoc = SigningIdentity.cdhashPrefix + String(repeating: "cd", count: 20)

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

  // decide(): swapping between a release install and a dev build, in both
  // directions — what a reviewer does when they drop the artifact over
  // /Applications/Blurt.app and then put the release DMG back.
  @Test func swappingBetweenReleaseAndDevBuildResets() {
    let toDevBuild = Migration.decide(
      lastIdentity: Self.team, currentIdentity: Self.adHoc, isTrusted: false)
    let backToRelease = Migration.decide(
      lastIdentity: Self.adHoc, currentIdentity: Self.team, isTrusted: false)
    #expect(toDevBuild == .resetThenRecord(Self.adHoc))
    #expect(backToRelease == .resetThenRecord(Self.team))
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
