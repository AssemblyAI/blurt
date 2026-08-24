import Foundation

/// The in-app equivalent of `scripts/reset-install.sh`: everything Blurt has put
/// on this machine, removed in one pass — the persisted settings, the Keychain
/// API key, the TCC grants (Accessibility, Microphone, Input Monitoring), and
/// the developer-mode logs — so someone whose install is in a bad state can get
/// back to preinstall without a terminal.
///
/// The one thing the script does that this can't is the LaunchServices
/// unregister sweep: that clears *other* copies of the app (DerivedData, stale
/// checkouts), which is a developer's problem and not something a running copy
/// can meaningfully do to itself. The script also covers both bundle ids, where
/// a running app can only reset its own.
///
/// **Not `Sendable`, and it doesn't need to be**: it is built and run in one
/// synchronous step on the main actor, from the Settings window's reset button.
/// The four steps are closures so the whole thing is exercisable without
/// touching the developer's own defaults, Keychain item, TCC rows, or logs —
/// `run()` is otherwise a function whose every effect is irreversible and
/// machine-wide, which is the last shape you want covered only by reading it.
public struct InstallReset {
  /// Title and body for the partial-reset alert. A named type rather than a
  /// tuple so the wording is assertable as a value, and so the shell has one
  /// thing to render.
  public struct AlertContent: Equatable, Sendable {
    public let title: String
    public let message: String
  }

  /// What survived the sweep. Each flag is one fallible step; clearing the
  /// settings can't fail (removing an absent default is a no-op), so it has no
  /// flag here.
  ///
  /// Internal: what the shell needs is "say this, or quit", which is what
  /// `run()` hands back. Keeping the per-step detail in here means the alert can
  /// name a step added later without the call site learning about it.
  struct Report {
    let apiKeyCleared: Bool
    let permissionsCleared: Bool
    let logsCleared: Bool

    /// What to tell the user when part of the reset didn't land, or `nil` when
    /// it all did. Owned here rather than at the `NSAlert` call site for the
    /// reason `UpdateAlertContent` is: it's a pure projection of a result into
    /// wording, and the shell that draws it has no test target — so a step
    /// added later can't ship with an alert that forgets to name it.
    var failureAlert: AlertContent? {
      let survivors = [
        apiKeyCleared ? nil : "your AssemblyAI API key",
        permissionsCleared ? nil : "Blurt’s microphone, accessibility and input-monitoring permissions",
        logsCleared ? nil : "the dictation logs",
      ].compactMap { $0 }
      guard !survivors.isEmpty else { return nil }
      return AlertContent(
        title: "Blurt wasn’t fully reset",
        message: "Couldn’t clear \(survivors.formatted(.list(type: .and))). "
          + "Everything else was reset. Quit Blurt and try again.")
    }
  }

  private let clearSettings: () -> Void
  private let clearAPIKey: () -> Bool
  private let resetPermissions: () -> Bool
  private let clearLogs: () -> Bool

  /// The production composition. `keyStore` is the *host's* storage seam rather
  /// than `APIKeyStore` directly, so a UI-test run clears its in-memory store
  /// instead of the developer's real Keychain item; `bundleID` must be the
  /// **running** one (`Bundle.main.bundleIdentifier`) for the reason spelled out
  /// on `PermissionsReset` — a dev build must never clear the released Blurt's
  /// grants.
  public init(bundleID: String, keyStore: any APIKeyGateway) {
    self.init(
      clearSettings: { PersistedSettings.resetAll() },
      clearAPIKey: { keyStore.save(nil) },
      resetPermissions: { PermissionsReset.resetAll(bundleID: bundleID) },
      clearLogs: { DictationLog.removeStoredLogs() })
  }

  /// The injectable composition the tests drive. Internal on purpose: the
  /// production entry point above is the door, and a public one here would
  /// invite a caller to assemble a reset that quietly skips a step.
  init(
    clearSettings: @escaping () -> Void,
    clearAPIKey: @escaping () -> Bool,
    resetPermissions: @escaping () -> Bool,
    clearLogs: @escaping () -> Bool
  ) {
    self.clearSettings = clearSettings
    self.clearAPIKey = clearAPIKey
    self.resetPermissions = resetPermissions
    self.clearLogs = clearLogs
  }

  /// Runs every step. Returns `nil` when the install is clean — the caller's cue
  /// that there is nothing to say — or the alert naming what survived.
  ///
  /// **No short-circuit.** A failed step never skips the ones after it: a
  /// half-reset install is exactly the state this exists to get out of, so
  /// stopping at the first failure would leave more behind than reporting it
  /// does. The order matches the script's — settings, key, permissions, logs —
  /// and nothing depends on it.
  public func run() -> AlertContent? {
    clearSettings()
    let apiKeyCleared = clearAPIKey()
    let permissionsCleared = resetPermissions()
    let logsCleared = clearLogs()
    return Report(
      apiKeyCleared: apiKeyCleared,
      permissionsCleared: permissionsCleared,
      logsCleared: logsCleared
    ).failureAlert
  }
}
