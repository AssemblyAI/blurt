import Foundation
import Security
import os

/// Integration adapters for the signing-identity migration: read this process's
/// own Team ID, and clear its Accessibility grant. Kept separate from the pure
/// `SigningIdentityMigration` so the decision logic stays testable and these
/// system calls stay thin.
public enum SigningIdentity {
  private static let log = Logger(subsystem: BlurtIdentity.subsystem, category: "SigningIdentity")

  /// The running binary's Team ID (the `subject.OU` the designated requirement
  /// pins), or `nil` for ad-hoc/unsigned code (local `swift build`, CI, UI-test
  /// hosts) — which is the signal the migration uses to no-op.
  public static func currentTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else { return nil }
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
      let dict = info as? [String: Any]
    else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
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
