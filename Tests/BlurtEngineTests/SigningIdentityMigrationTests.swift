import Testing

@testable import BlurtEngine

@Suite struct SigningIdentityMigrationTests {
  private typealias Migration = SigningIdentityMigration

  // decide(): unsigned/ad-hoc builds never act.
  @Test func unsignedNeverActs() {
    #expect(Migration.decide(lastTeam: nil, currentTeam: nil, isTrusted: false) == .noAction)
    #expect(Migration.decide(lastTeam: "OLD", currentTeam: nil, isTrusted: true) == .noAction)
  }

  // decide(): same team as last launch is steady state, regardless of trust.
  @Test func steadyStateIsNoAction() {
    #expect(Migration.decide(lastTeam: "NEW", currentTeam: "NEW", isTrusted: false) == .noAction)
    #expect(Migration.decide(lastTeam: "NEW", currentTeam: "NEW", isTrusted: true) == .noAction)
  }

  // decide(): no marker (every currently-shipped user) is treated as changed.
  @Test func firstSeenUntrustedResets() {
    #expect(Migration.decide(lastTeam: nil, currentTeam: "NEW", isTrusted: false) == .resetThenRecord("NEW"))
  }
  @Test func firstSeenTrustedRecordsOnly() {
    #expect(Migration.decide(lastTeam: nil, currentTeam: "NEW", isTrusted: true) == .recordTeam("NEW"))
  }

  // decide(): an actual team change.
  @Test func teamChangedUntrustedResets() {
    #expect(Migration.decide(lastTeam: "OLD", currentTeam: "NEW", isTrusted: false) == .resetThenRecord("NEW"))
  }
  @Test func teamChangedTrustedRecordsOnly() {
    #expect(Migration.decide(lastTeam: "OLD", currentTeam: "NEW", isTrusted: true) == .recordTeam("NEW"))
  }

  // run(): steady state / unsigned persist nothing and never reset.
  @Test func runNoActionPersistsNothingAndSkipsReset() {
    let out = Migration.run(lastTeam: "NEW", currentTeam: "NEW", isTrusted: false) {
      Issue.record("reset must not run for .noAction")
      return true
    }
    #expect(out == nil)
  }

  // run(): trusted team change records without resetting.
  @Test func runRecordsWithoutResetting() {
    var didReset = false
    let out = Migration.run(lastTeam: "OLD", currentTeam: "NEW", isTrusted: true) {
      didReset = true
      return true
    }
    #expect(out == "NEW")
    #expect(didReset == false)
  }

  // run(): untrusted team change resets, then persists only on success.
  @Test func runResetsThenPersistsOnSuccess() {
    #expect(Migration.run(lastTeam: "OLD", currentTeam: "NEW", isTrusted: false) { true } == "NEW")
  }
  @Test func runDoesNotPersistWhenResetFails() {
    #expect(Migration.run(lastTeam: "OLD", currentTeam: "NEW", isTrusted: false) { false } == nil)
  }
}
