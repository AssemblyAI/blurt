import Testing

@testable import BlurtEngine

@Suite("SigningIdentity")
struct SigningIdentityTests {

  // What the test host reports depends on how it was signed (ad-hoc under
  // `swift test`, team-signed under Xcode), so these assert shape and stability
  // rather than a literal. `includingAdHoc: false` is the narrower answer the
  // UI-test build asks for: team identities only.
  private static func identity() -> String? { SigningIdentity.current(includingAdHoc: true) }
  private static func teamIdentity() -> String? { SigningIdentity.current(includingAdHoc: false) }

  // The value the migration compares must be a property of the *binary*, not of
  // the moment it was read — an identity that varied per call would reset the
  // Accessibility grant on every launch.
  @Test("current() is stable across reads")
  func currentIsStable() {
    #expect(Self.identity() == Self.identity())
  }

  @Test("a Team ID is the identity verbatim, ad-hoc or not")
  func teamIdentityIsUnprefixed() {
    // Frozen value shape: builds that predate the ad-hoc case recorded a bare Team
    // ID, and a signed app must keep matching that marker rather than re-running
    // the `tccutil` reset once on every installed machine. A team-signed build
    // also answers the same either way — `includingAdHoc` only decides what
    // happens when there is no team.
    guard let team = Self.teamIdentity() else { return }
    #expect(Self.identity() == team)
  }

  @Test("an ad-hoc identity is a namespaced hex cdhash")
  func adHocIdentityIsAPrefixedCdhash() {
    guard Self.teamIdentity() == nil, let identity = Self.identity() else {
      return  // team-signed host, or code with no signature at all
    }
    #expect(identity.hasPrefix(SigningIdentity.cdhashPrefix))
    let hex = identity.dropFirst(SigningIdentity.cdhashPrefix.count)
    // SHA-1-truncated cdhash: 20 bytes, so 40 hex digits (longer for other digest
    // choices — the length floor is what matters, not the exact algorithm).
    #expect(hex.count >= 40)
    // Hoisted out of the macro on purpose: `#expect` rewrites a call into
    // `__checkFunctionCall(hex.self, calling: { $0.allSatisfy($1) }, …)`, and that
    // rewrite loses `allSatisfy`'s `rethrows`-ness — the expansion won't compile
    // without a `try` it has no use for. Don't inline it back.
    let isHex = hex.allSatisfy(\.isHexDigit)
    #expect(isHex)
    // …and the prefix keeps it out of the Team ID's namespace: a Team ID is 10
    // alphanumerics, so a colon is what a recorded marker can be told apart by.
    #expect(identity.contains(":"))
  }

  @Test("includingAdHoc: false never reports a cdhash")
  func adHocIsIdentityLessWhenExcluded() {
    // The UI-test build's carve-out. Under `swift test` the host is ad-hoc signed,
    // so this is the case that matters: no identity at all, which the migration
    // reads as "no action" and never spawns `tccutil` for.
    guard let team = Self.teamIdentity() else { return }
    #expect(!team.hasPrefix(SigningIdentity.cdhashPrefix))
  }
}
