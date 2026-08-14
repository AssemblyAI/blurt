#if os(macOS)
  import Testing

  @testable import BlurtEngine

  @Suite struct SigningIdentityMigrationTests {
    private typealias Migration = SigningIdentityMigration

    // The identities `SigningIdentity.current()` produces, one per way Blurt is
    // signed. The migration treats them alike — it only ever compares strings — but
    // which pairs of them differ is the whole reason the cases below exist, so they
    // are spelled out rather than left implied.
    //
    // A dev build's requirement is explicit and team-based (stamped by the
    // `project.yml` post-build install, stable across cert rotation); a release
    // carries codesign's default, which names the leaf certificate — so re-issuing
    // that certificate produces `reissuedRelease` and orphans the grant.
    private static let prefix = SigningIdentity.requirementPrefix
    private static let anchor = "identifier \"dev.alex.blurt\" and anchor apple generic"
    private static let devBuild = "\(prefix)\(anchor) and certificate leaf[subject.OU] = \"B2VQF7Q2QY\""
    private static let release = "\(prefix)\(anchor) and certificate leaf[subject.CN] = \"Dev ID 2024\""
    private static let reissuedRelease =
      "\(prefix)\(anchor) and certificate leaf[subject.CN] = \"Dev ID 2029\""

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

    // decide(): any identity change at all.
    @Test func identityChangedUntrustedResets() {
      let decision = Migration.decide(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: false)
      #expect(decision == .resetThenRecord("NEW"))
    }
    @Test func identityChangedTrustedRecordsOnly() {
      let decision = Migration.decide(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: true)
      #expect(decision == .record("NEW"))
    }

    // decide(): the case this exists for now that debug builds carry their own
    // bundle id. Re-issuing the Developer ID certificate (RELEASE.md's rotation
    // procedure) changes the leaf its default requirement names, so every installed
    // user's grant is suddenly pinned to a requirement the update cannot satisfy —
    // switched on in System Settings, denied by `AXIsProcessTrusted()`, with no way
    // past the wizard. Nothing at signing time can pre-empt it: the requirement was
    // handed to `tccd` before the rotation existed.
    @Test func reissuedReleaseCertificateResets() {
      let decision = Migration.decide(
        lastIdentity: Self.release, currentIdentity: Self.reissuedRelease, isTrusted: false)
      #expect(decision == .resetThenRecord(Self.reissuedRelease))
    }

    // decide(): the flip side — the identity must be *stable* for the loop that
    // rebuilds the same way over and over. Two `dev-build.sh` runs pin the same
    // team-based requirement, so a working grant survives a rebuild; nothing here
    // may reset on every launch.
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
#endif
