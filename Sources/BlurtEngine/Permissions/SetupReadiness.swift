/// The policy behind first-run setup: what counts as "fully configured", and how
/// briskly to poll the permissions that feed that answer.
///
/// Owned in the engine because none of it needs AppKit and all of it is a rule
/// rather than plumbing — `WizardController`, which applied it inline, has no
/// test target, so the gate and the cadence were covered by nothing.
public enum SetupReadiness {
  /// Whether the app is fully configured: every permission granted and an API
  /// key saved.
  ///
  /// The dictation shortcut is deliberately **not** part of this gate — it has a
  /// default binding and is rebound in Settings, so a shortcut change can never
  /// trap the user back in the wizard.
  public static func isReady(permissions: PermissionStatus, hasAPIKey: Bool) -> Bool {
    permissions.allGranted && hasAPIKey
  }

  /// Poll cadence while the user is still setting up: brisk, so a permission
  /// granted over in System Settings shows as "Granted" almost at once — the
  /// user is watching this window.
  public static let settingUpPollInterval: Duration = .seconds(1)

  /// Poll cadence once configured: coasting. The poll then only has to catch a
  /// rare revocation, so there's no reason to wake the main actor every second
  /// for the rest of the app's life.
  public static let readyPollInterval: Duration = .seconds(5)

  /// How long to wait before the next permission poll, given where setup stands.
  public static func pollInterval(isReady: Bool) -> Duration {
    isReady ? readyPollInterval : settingUpPollInterval
  }
}
