import Foundation
import Security
import os

/// Integration adapters for the signing-identity migration: read the identity
/// this process's signature pins into its designated requirement, and clear its
/// Accessibility grant. Kept separate from the pure `SigningIdentityMigration`
/// so the decision logic stays testable and these system calls stay thin.
public enum SigningIdentity {
  private static let log = Logger(subsystem: BlurtIdentity.subsystem, category: "SigningIdentity")

  /// Prefix marking a cdhash identity, so it can never be mistaken for a bare
  /// Team ID (10 alphanumerics, no colon) — the value shape already persisted by
  /// every build that predates the ad-hoc case.
  static let cdhashPrefix = "cdhash:"

  /// Whatever an Accessibility grant taken *right now* would be pinned to.
  ///
  /// Two shapes, because the two kinds of build Blurt produces pin different
  /// things into their designated requirement:
  ///
  /// - **Team-signed** (`Apple Development` locally, `Developer ID` for a
  ///   release): `project.yml` stamps an explicit team-based requirement, so the
  ///   Team ID *is* the identity — cert rotation inside the team keeps the grant
  ///   and must not read as a change.
  /// - **Ad-hoc** (`CODE_SIGN_IDENTITY="-"`, i.e. the `Debug-Local` artifact
  ///   `check.yml` builds for every PR): there is no team and no explicit
  ///   requirement, and codesign's default for ad-hoc code pins the *cdhash* —
  ///   a different value for every build. Successive dev builds are therefore
  ///   different apps to `tccd`, which is what strands a reviewer in front of a
  ///   Blurt row that is switched on while `AXIsProcessTrusted()` keeps saying no.
  ///
  /// `nil` for code carrying no signature at all — and, when `includingAdHoc` is
  /// false, for any ad-hoc build. Both are the signal the migration uses to no-op.
  ///
  /// - Parameter includingAdHoc: whether a cdhash counts as an identity. The
  ///   UI-test build passes `false`: `uitest.sh` and `check.sh` sign the app
  ///   ad-hoc under the shipping bundle id, so honouring a cdhash there would make
  ///   every local test run reset the developer's real Blurt grant.
  public static func current(includingAdHoc: Bool) -> String? {
    let info = signingInformation()
    if let team = info[kSecCodeInfoTeamIdentifier as String] as? String { return team }
    guard includingAdHoc, let cdhash = info[kSecCodeInfoUnique as String] as? Data else {
      return nil
    }
    return cdhashPrefix + cdhash.map { String(format: "%02x", $0) }.joined()
  }

  /// This process's signing information — empty when it carries no signature, or
  /// when any step of the `Security` handshake fails. Empty rather than `nil`
  /// because "no information" and "an absence of these keys" lead every caller to
  /// the same answer, and an optional collection is two ways to say nothing (the
  /// `discouraged_optional_collection` lint rule).
  private static func signingInformation() -> [String: Any] {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return [:] }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else { return [:] }
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
      let dict = info as? [String: Any]
    else { return [:] }
    return dict
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
