import Foundation
import Security
import os

/// Integration adapters for the signing-identity migration: read the identity
/// this process's signature pins into its designated requirement, and clear its
/// Accessibility grant. Kept separate from the pure `SigningIdentityMigration`
/// so the decision logic stays testable and these system calls stay thin.
public enum SigningIdentity {
  private static let log = HostIdentity.current.logger("SigningIdentity")

  /// Namespace marker on a recorded identity. Every build before this one recorded
  /// a bare Team ID (10 alphanumerics, no colon), so the prefix keeps the two
  /// shapes disjoint — a marker left by an older build can never accidentally
  /// compare equal to a requirement — and makes a dumped `defaults read` value
  /// self-describing.
  static let requirementPrefix = "dr:"

  /// Whatever an Accessibility grant taken *right now* would be pinned to: this
  /// binary's **designated requirement**, serialized.
  ///
  /// The DR is what `tccd` stores alongside a grant and re-checks the running
  /// binary against, so it is the identity — not a proxy for it. That distinction
  /// is the whole bug this used to have: it recorded the *Team ID*, and the two
  /// ways Blurt is team-signed carry the same team while pinning different
  /// requirements.
  ///
  /// - **Dev builds** (`Apple Development`, re-signed by the `project.yml`
  ///   post-build install) pin an explicit team-based requirement:
  ///   `identifier … and anchor apple generic and certificate leaf[subject.OU] = <team>`.
  ///   Cert rotation inside the team leaves that string byte-identical, which is
  ///   why the explicit requirement is stamped in the first place.
  /// - **Releases** (`Developer ID`, `scripts/release-build.sh`) carry codesign's
  ///   *default* requirement, which additionally pins the leaf cert's Common Name
  ///   and the Developer ID marker OIDs — so re-issuing that certificate moves the
  ///   requirement and orphans every installed user's grant.
  ///
  /// `nil` for **unsigned or ad-hoc code**, which the migration reads as "no
  /// action". Ad-hoc signatures pin a cdhash, so honouring them would mean every
  /// `uitest.sh` / `check.sh` run — each one a throwaway ad-hoc binary under the
  /// debug bundle id — resetting the developer's own Blurt Dev grant. Refusing
  /// them here makes that structural rather than a flag the call site has to
  /// remember to pass. The cost is a contributor who builds ad-hoc *and* copies
  /// the result to /Applications by hand: they re-grant per rebuild, and
  /// `tccutil reset Accessibility dev.alex.blurt.dev` is the way out.
  public static func current() -> String? {
    guard let code = staticCodeForSelf() else { return nil }
    // A team identifier is present exactly when the signature isn't ad-hoc, so it
    // is the probe for that carve-out — never the recorded value.
    guard teamIdentifier(of: code) != nil else { return nil }
    guard let requirement = designatedRequirement(of: code) else { return nil }
    return requirementPrefix + requirement
  }

  /// The on-disk code object backing this process, or `nil` when any step of the
  /// `Security` handshake fails.
  static func staticCodeForSelf() -> SecStaticCode? {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode
    else { return nil }
    return staticCode
  }

  /// The signature's team identifier — `nil` for unsigned or ad-hoc code.
  private static func teamIdentifier(of code: SecStaticCode) -> String? {
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
      let dict = info as? [String: Any]
    else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
  }

  /// The designated requirement, serialized to the same text `codesign -d -r-`
  /// prints. Read through `SecCodeCopyDesignatedRequirement` rather than the
  /// `kSecCodeInfoDesignatedRequirement` key of the signing-information
  /// dictionary: that dictionary is `[String: Any]`, and narrowing an `Any` back
  /// to a CoreFoundation type needs a cast the compiler flags as always-succeeding
  /// (or a banned force cast). This spelling is typed end to end.
  ///
  /// Takes the code object rather than reading `self` so the tests can point it at
  /// a binary whose requirement is known — the whole `Security` handshake is the
  /// one part of this file that isn't pure logic, and the test host's own
  /// signature varies by how the suite was launched.
  static func designatedRequirement(of code: SecStaticCode) -> String? {
    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess,
      let requirement
    else { return nil }
    var text: CFString?
    guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess, let text
    else { return nil }
    return text as String
  }

  /// Clears Blurt's Accessibility TCC grant so the next authorization recaptures a
  /// code requirement matching the current signature. Resetting a bundle's own
  /// grant needs no admin rights. Returns whether `tccutil` exited 0.
  @discardableResult
  public static func resetAccessibilityGrant(bundleID: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
    proc.arguments = ["reset", "Accessibility", bundleID]
    do {
      try proc.run()
      proc.waitUntilExit()
      let ok = proc.terminationStatus == 0
      if !ok { log.warning("tccutil reset Accessibility exited \(proc.terminationStatus)") }
      return ok
    } catch {
      log.error("tccutil reset Accessibility failed to launch: \(error.localizedDescription)")
      return false
    }
  }
}
