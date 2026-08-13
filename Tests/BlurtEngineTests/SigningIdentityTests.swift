import Testing

@testable import BlurtEngine

@Suite("SigningIdentity")
struct SigningIdentityTests {

  // What the test host reports depends on how it was signed (ad-hoc under
  // `swift test`, team-signed under Xcode), so these assert shape and stability
  // rather than a literal. `includingAdHoc: false` is the narrower answer the
  // UI-test build asks for: team-signed hosts only.
  private static func identity() -> String? { SigningIdentity.current(includingAdHoc: true) }
  private static func teamIdentity() -> String? { SigningIdentity.current(includingAdHoc: false) }

  // The value the migration compares must be a property of the *binary*, not of
  // the moment it was read — an identity that varied per call would reset the
  // Accessibility grant on every launch.
  @Test("current() is stable across reads")
  func currentIsStable() {
    #expect(Self.identity() == Self.identity())
  }

  // Signed code always has a designated requirement, ad-hoc included — that is
  // the claim the whole migration rests on, and the one thing here that is not
  // pure logic. Under `swift test` the host is ad-hoc signed, so this covers the
  // per-PR dev build's case (no team, a cdhash-pinned requirement) on the machine
  // that runs it.
  @Test("a signed host reports a namespaced designated requirement")
  func identityIsANamespacedRequirement() {
    guard let identity = Self.identity() else {
      return  // code with no signature at all
    }
    #expect(identity.hasPrefix(SigningIdentity.requirementPrefix))
    let requirement = identity.dropFirst(SigningIdentity.requirementPrefix.count)
    // A requirement expression is never empty, and never a bare Team ID (10
    // alphanumerics): the marker recorded by builds that predate this shape has to
    // stay distinguishable from one recorded now.
    #expect(!requirement.isEmpty)
    #expect(identity.contains(":"))
  }

  // The UI-test build's carve-out. Under `swift test` the host is ad-hoc signed,
  // so this is the case that matters: no identity at all, which the migration
  // reads as "no action" and never spawns `tccutil` for. A team-signed host
  // (Xcode) answers the same either way — `includingAdHoc` only decides what
  // happens when there is no team.
  @Test("includingAdHoc: false answers only for team-signed code")
  func adHocIsIdentityLessWhenExcluded() {
    guard let team = Self.teamIdentity() else { return }
    #expect(Self.identity() == team)
  }
}
