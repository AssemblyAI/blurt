#if os(macOS)
  import Testing

  @testable import BlurtEngine

  @Suite
  struct SigningIdentityMigrationTests {
    private typealias Migration = SigningIdentityMigration

    /// One `decide()` input — last launch's identity, this launch's, and the live
    /// trust state — and the decision it must produce.
    struct DecideCase: Sendable, CustomTestStringConvertible {
      let name: String
      let last: String?
      let current: String?
      let isTrusted: Bool
      let expected: SigningIdentityMigration.Decision
      var testDescription: String { name }
    }

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

    static let decideCases: [DecideCase] = [
      // Unsigned builds never act.
      DecideCase(
        name: "unsigned, untrusted, never seen",
        last: nil,
        current: nil,
        isTrusted: false,
        expected: .noAction
      ),
      DecideCase(
        name: "unsigned, trusted, seen before",
        last: "OLD",
        current: nil,
        isTrusted: true,
        expected: .noAction
      ),
      // The same identity as last launch is steady state, regardless of trust.
      DecideCase(
        name: "steady state, untrusted",
        last: "NEW",
        current: "NEW",
        isTrusted: false,
        expected: .noAction
      ),
      DecideCase(
        name: "steady state, trusted",
        last: "NEW",
        current: "NEW",
        isTrusted: true,
        expected: .noAction
      ),
      // No marker (every build predating it) is treated as changed.
      DecideCase(
        name: "first seen, untrusted, resets",
        last: nil,
        current: "NEW",
        isTrusted: false,
        expected: .resetThenRecord("NEW")
      ),
      DecideCase(
        name: "first seen, trusted, records only",
        last: nil,
        current: "NEW",
        isTrusted: true,
        expected: .record("NEW")
      ),
      // Any identity change at all.
      DecideCase(
        name: "identity changed, untrusted, resets",
        last: "OLD",
        current: "NEW",
        isTrusted: false,
        expected: .resetThenRecord("NEW")
      ),
      DecideCase(
        name: "identity changed, trusted, records only",
        last: "OLD",
        current: "NEW",
        isTrusted: true,
        expected: .record("NEW")
      ),
    ]

    @Test("decide resets only an untrusted identity change, and records any change", arguments: decideCases)
    func decide(_ c: DecideCase) {
      #expect(
        Migration.decide(lastIdentity: c.last, currentIdentity: c.current, isTrusted: c.isTrusted) == c.expected)
    }

    // decide(): the case this exists for now that debug builds carry their own
    // bundle id. Re-issuing the Developer ID certificate (RELEASE.md's rotation
    // procedure) changes the leaf its default requirement names, so every installed
    // user's grant is suddenly pinned to a requirement the update cannot satisfy —
    // switched on in System Settings, denied by `AXIsProcessTrusted()`, with no way
    // past the wizard. Nothing at signing time can pre-empt it: the requirement was
    // handed to `tccd` before the rotation existed.
    @Test
    func reissuedReleaseCertificateResets() {
      let decision = Migration.decide(
        lastIdentity: Self.release, currentIdentity: Self.reissuedRelease, isTrusted: false
      )
      #expect(decision == .resetThenRecord(Self.reissuedRelease))
    }

    // decide(): the flip side — the identity must be *stable* for the loop that
    // rebuilds the same way over and over. Two `dev-build.sh` runs pin the same
    // team-based requirement, so a working grant survives a rebuild; nothing here
    // may reset on every launch.
    @Test
    func rebuildingTheSameWayIsNoAction() {
      #expect(
        Migration.decide(lastIdentity: Self.devBuild, currentIdentity: Self.devBuild, isTrusted: true)
          == .noAction)
      #expect(
        Migration.decide(lastIdentity: Self.release, currentIdentity: Self.release, isTrusted: false)
          == .noAction)
    }

    // run(): steady state / unsigned persist nothing and never reset.
    @Test
    func runNoActionPersistsNothingAndSkipsReset() {
      let out = Migration.run(lastIdentity: "NEW", currentIdentity: "NEW", isTrusted: false) {
        Issue.record("reset must not run for .noAction")
        return true
      }
      #expect(out == nil)
    }

    // run(): a trusted identity change records without resetting.
    @Test
    func runRecordsWithoutResetting() {
      var didReset = false
      let out = Migration.run(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: true) {
        didReset = true
        return true
      }
      #expect(out == "NEW")
      #expect(didReset == false)
    }

    // run(): an untrusted identity change resets, then persists only on success.
    @Test
    func runResetsThenPersistsOnSuccess() {
      let out = Migration.run(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: false) { true }
      #expect(out == "NEW")
    }
    @Test
    func runDoesNotPersistWhenResetFails() {
      let out = Migration.run(lastIdentity: "OLD", currentIdentity: "NEW", isTrusted: false) { false }
      #expect(out == nil)
    }
  }
#endif
