import Foundation
import os

/// Clears the TCC grants an install holds, by running `tccutil reset <service>`
/// against a bundle id. The in-process half of what `scripts/reset-install.sh`
/// does from a terminal, so the Settings window's reset can offer the same thing
/// without one.
///
/// Resetting a bundle's *own* grants needs no admin rights, which is what makes
/// this usable from the app at all. It is still a system call with no dry run:
/// pass the **running** bundle id (`Bundle.main.bundleIdentifier`), never
/// `HostIdentity.current.subsystem` — debug builds ship under
/// `dev.alex.blurt.dev` (see `project.yml`), so the constant would have a dev
/// build clearing the released Blurt's grants, the one app whose permissions
/// this process has no business touching.
public enum PermissionsReset {
  private static let log = HostIdentity.current.logger("PermissionsReset")

  /// The TCC services a Blurt install can hold a grant under — the set
  /// `resetAll` sweeps, and the same three `scripts/reset-install.sh` lists
  /// (bash can't read this enum, so the two are kept in step by hand).
  ///
  /// Raw values are `tccutil`'s own service names, which are not all the names
  /// System Settings shows.
  public enum Service: String, CaseIterable, Sendable {
    /// Typing into other apps, and the focused-field reads that feed the paste
    /// path (`KeyInjector`, `FocusCapture`).
    case accessibility = "Accessibility"
    /// Recording (`MicCapture`).
    case microphone = "Microphone"
    /// Input Monitoring — the `CGEventTap` behind the hold-to-dictate hotkey
    /// (`DictationKeyTap`). `tccutil` knows it by its internal name,
    /// `ListenEvent`.
    case inputMonitoring = "ListenEvent"
  }

  /// Clears `service` for `bundleID`. Returns whether `tccutil` exited 0 — a
  /// non-zero exit (or a launch failure) is reported rather than thrown, since
  /// every caller's answer to a failed reset is the same: say so, and leave the
  /// rest of the sweep to run.
  @discardableResult
  public static func reset(_ service: Service, bundleID: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
    proc.arguments = ["reset", service.rawValue, bundleID]
    do {
      try proc.run()
      proc.waitUntilExit()
      let ok = proc.terminationStatus == 0
      if !ok {
        log.warning(
          "tccutil reset \(service.rawValue, privacy: .public) exited \(proc.terminationStatus)")
      }
      return ok
    } catch {
      let reason = error.localizedDescription
      log.error(
        "tccutil reset \(service.rawValue, privacy: .public) failed to launch: \(reason, privacy: .public)")
      return false
    }
  }

  /// The services a full reset sweeps. Spelled out case by case rather than
  /// taken from `allCases` because Periphery can't follow a case that is only
  /// ever reached through `allCases` and reports it as dead;
  /// `PermissionsResetTests` pins this list against `allCases`, so a service
  /// added to the enum and forgotten here fails there rather than silently
  /// surviving every "full" reset.
  static let sweep: [Service] = [.accessibility, .microphone, .inputMonitoring]

  /// Clears every service in `sweep` for `bundleID`, returning true only when
  /// all of them succeeded. Every service is attempted even after one fails: a
  /// half-reset install is the state this exists to get *out* of, so stopping at
  /// the first failure would leave more behind than reporting it does.
  @discardableResult
  static func resetAll(bundleID: String) -> Bool {
    var allCleared = true
    for service in sweep where !reset(service, bundleID: bundleID) {
      allCleared = false
    }
    return allCleared
  }
}
