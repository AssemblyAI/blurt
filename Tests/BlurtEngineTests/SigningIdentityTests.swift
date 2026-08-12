import Testing

@testable import BlurtEngine

@Suite("SigningIdentity")
struct SigningIdentityTests {

  // The value the migration compares must be a property of the *binary*, not of
  // the moment it was read — an identity that varied per call would reset the
  // Accessibility grant on every launch. What the test host reports depends on how
  // it was signed (ad-hoc under `swift test`, teamed under Xcode), so the
  // assertions are about shape and stability rather than a literal.
  @Test("current() is stable across reads")
  func currentIsStable() {
    #expect(SigningIdentity.current() == SigningIdentity.current())
  }

  @Test("current() prefers the Team ID, verbatim")
  func teamIdentityIsUnprefixed() {
    // Frozen value shape: builds that predate the ad-hoc case recorded a bare Team
    // ID, and a signed app must keep matching that marker rather than re-running
    // the `tccutil` reset once on every installed machine.
    guard let team = SigningIdentity.currentTeamIdentifier() else { return }
    #expect(SigningIdentity.current() == team)
  }

  @Test("an ad-hoc identity is a namespaced hex cdhash")
  func adHocIdentityIsAPrefixedCdhash() {
    guard SigningIdentity.currentTeamIdentifier() == nil,
      let identity = SigningIdentity.current()
    else { return }  // team-signed host, or code with no signature at all
    #expect(identity.hasPrefix(SigningIdentity.cdhashPrefix))
    let hex = identity.dropFirst(SigningIdentity.cdhashPrefix.count)
    // SHA-1-truncated cdhash: 20 bytes, so 40 hex digits (longer for other digest
    // choices — the length floor is what matters, not the exact algorithm).
    #expect(hex.count >= 40)
    #expect(hex.allSatisfy(\.isHexDigit))
    // …and the prefix keeps it out of the Team ID's namespace: a Team ID is 10
    // alphanumerics, so a colon is what a recorded marker can be told apart by.
    #expect(identity.contains(":"))
  }
}
