/// Whether Blurt's one-time setup is complete.
///
/// Decides when the app is *fully configured* so the dictation overlay can
/// appear and the main window can show its "ready" screen. Setup is complete
/// once all permissions are granted and an API key is saved. The dictation
/// shortcut is deliberately not part of this gate: it ships with a default
/// binding and is rebound in Settings (not onboarding), so a cleared shortcut
/// surfaces as a hint on the ready screen instead of trapping the user in the
/// setup wizard.
public enum SetupStatus {
  public static func isReady(
    permissions: PermissionStatus,
    hasAPIKey: Bool
  ) -> Bool {
    permissions.allGranted && hasAPIKey
  }
}
