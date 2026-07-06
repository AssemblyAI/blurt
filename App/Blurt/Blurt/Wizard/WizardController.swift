import BlurtEngine
import Observation

/// Backs first-run setup. Setup is a single page — the API key and the two
/// permissions are all shown at once — and the main window shows it whenever the
/// app isn't fully configured. Once every permission is granted and a key is
/// saved, `isReady` flips and the main window swaps to its "ready" screen.
///
/// This owns the live permission status (refreshed on demand and polled for the
/// app's whole life) and reveals the dictation overlay once setup is complete. If
/// a permission is later revoked — even while the app is sitting in the
/// background with only the overlay pill — the poll catches it and brings the
/// setup window forward.
@Observable
final class WizardController {
  private(set) var permissions: PermissionStatus

  @ObservationIgnored private weak var coordinator: AppCoordinator?
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  /// Brings the setup window forward and activates the app. Invoked when a
  /// previously-configured app loses a requirement (e.g. a revoked permission) so
  /// the user is taken back to onboarding instead of left with a dead overlay.
  @ObservationIgnored private let onNeedsForeground: @MainActor () -> Void
  /// Last-seen readiness, so overlay visibility is driven by *transitions*: the
  /// pill is shown when the app becomes configured and hidden when it stops being
  /// configured. Tracking the edge (rather than calling show on every poll tick)
  /// keeps a steady-state poll from stomping the live recording pill back to idle.
  @ObservationIgnored private var wasReady = false

  init(coordinator: AppCoordinator, onNeedsForeground: @escaping @MainActor () -> Void) {
    self.coordinator = coordinator
    self.onNeedsForeground = onNeedsForeground
    self.permissions = PermissionsChecker.check()
    syncOverlay()
    // React the moment the API key changes, rather than waiting up to a second
    // for the next permission poll, so the overlay appears as soon as the last
    // missing piece is supplied (or hides the instant one is removed).
    observeCoordinatorReadiness()
    // Poll for the app's whole life so a permission revoked while no window is
    // open still kicks the user back into onboarding.
    startPolling()
  }

  /// Whether the app is fully configured (all permissions + a saved key). Drives
  /// the main window's wizard-vs-ready routing. The dictation shortcut is *not*
  /// part of this gate — it has a default binding and is rebound in Settings, so
  /// a cleared shortcut surfaces as a hint on the ready screen rather than
  /// trapping the user in the wizard.
  var isReady: Bool {
    SetupStatus.isReady(
      permissions: permissions,
      hasAPIKey: coordinator?.hasAPIKey ?? false
    )
  }

  /// Observes the coordinator's readiness input (`hasAPIKey`) via the Observation
  /// framework. `withObservationTracking` fires its `onChange` exactly once,
  /// *before* the mutation commits, so we react on the next main-actor tick and
  /// then re-arm for the following change. This reveals the overlay the moment a
  /// verified key is saved rather than waiting for the next permission poll.
  private func observeCoordinatorReadiness() {
    guard let coordinator else { return }
    withObservationTracking {
      _ = coordinator.hasAPIKey
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.syncOverlay()
        self.observeCoordinatorReadiness()
      }
    }
  }

  /// Starts the lifetime permission poll so a permission granted in System
  /// Settings (or revoked later) is reflected without the user having to re-tap a
  /// button — and without depending on the setup window being open. Idempotent.
  private func startPolling() {
    pollTask?.cancel()
    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        // Poll briskly during setup so a freshly-granted permission shows at
        // once; once configured, coast — the poll then only needs to catch a
        // rare revocation, not wake the main actor every second for the app's
        // whole life. (`self?` keeps the controller releasable across the sleep.)
        let interval: Duration = (self?.isReady ?? false) ? .seconds(5) : .seconds(1)
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, let self else { return }
        self.refreshPermissions()
      }
    }
  }

  /// Re-checks permissions immediately — used after the user taps a grant button
  /// so the row flips to "Granted" without waiting for the next poll tick, and by
  /// the lifetime poll to catch a permission revoked outside the app.
  func refreshPermissions() {
    let perms = PermissionsChecker.check()
    // A permission that was granted and is now gone (revoked in System Settings,
    // possibly while no window was open) should pull the user back into onboarding.
    let revoked = permissions.allGranted && !perms.allGranted
    if perms != permissions {
      permissions = perms
    }
    syncOverlay()
    if revoked { onNeedsForeground() }
  }

  /// Drives overlay visibility from readiness transitions: show the pill when the
  /// app becomes fully configured, hide it when it stops being configured. Acting
  /// only on the edge keeps a steady-state poll tick from re-showing the idle
  /// pill over a live recording. (Pulling the user back into onboarding on a
  /// revocation is handled in `refreshPermissions`, where the cause is known.)
  private func syncOverlay() {
    let ready = isReady
    guard ready != wasReady else { return }
    wasReady = ready
    if ready {
      coordinator?.showOverlay()
    } else {
      coordinator?.hideOverlay()
    }
  }

  deinit {
    pollTask?.cancel()
  }
}
