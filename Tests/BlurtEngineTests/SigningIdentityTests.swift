import Foundation
import Security
import Testing

@testable import BlurtEngine

@Suite("SigningIdentity")
struct SigningIdentityTests {

  // The value the migration compares must be a property of the *binary*, not of
  // the moment it was read — an identity that varied per call would reset the
  // Accessibility grant on every launch.
  @Test("current() is stable across reads")
  func currentIsStable() {
    #expect(SigningIdentity.current() == SigningIdentity.current())
  }

  // What the test host reports depends on how it was signed (ad-hoc under
  // `swift test`, team-signed under Xcode), so this asserts the shape of whatever
  // this host gives rather than a literal — including the shape of "nothing",
  // which is the answer for the ad-hoc host and the one the migration reads as
  // "no action".
  @Test("current() is either absent or a namespaced requirement")
  func currentIsNamespacedWhenPresent() {
    guard let identity = SigningIdentity.current() else {
      return  // ad-hoc or unsigned host: refusing to answer is the contract
    }
    #expect(identity.hasPrefix(SigningIdentity.requirementPrefix))
    // Never a bare Team ID (10 alphanumerics, no colon): the marker recorded by
    // builds that predate this shape has to stay distinguishable from one
    // recorded now, or an upgrade would read as steady state.
    #expect(identity.contains(":"))
    #expect(identity.count > SigningIdentity.requirementPrefix.count)
  }

  // The `Security` handshake is the one part of this file that isn't pure logic,
  // and the host's own signature can't exercise it (ad-hoc under `swift test`).
  // `/bin/ls` can: it is present on every Mac and Apple-signed, so its designated
  // requirement is both readable and known. If this returns nil the migration
  // silently degrades to "never act" — a grant orphaned by a re-issued release
  // certificate would then strand every user with no way past the wizard.
  @Test("a designated requirement can actually be read")
  func designatedRequirementIsReadable() throws {
    var code: SecStaticCode?
    let status = SecStaticCodeCreateWithPath(
      URL(fileURLWithPath: "/bin/ls") as CFURL, SecCSFlags(), &code)
    #expect(status == errSecSuccess)
    let staticCode = try #require(code)
    let requirement = try #require(SigningIdentity.designatedRequirement(of: staticCode))
    #expect(requirement.contains("anchor apple"))
  }

  // The process's own code object has to resolve, or `current()` can only ever
  // answer nil and the migration is dead weight in every build.
  @Test("this process's code object resolves")
  func selfStaticCodeResolves() throws {
    _ = try #require(SigningIdentity.staticCodeForSelf())
  }
}
