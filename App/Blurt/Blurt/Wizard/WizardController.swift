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

  /// Whether the app is fully configured (all permissions + a saved key). Drives
  /// the main window's wizard-vs-ready routing and, off its transitions, the
  /// overlay's show/hide.
  ///
  /// Stored (not computed) on purpose. `MainWindowRoot` observes this to route
  /// between the wizard and ready screens; if it read a value computed live over
  /// `permissions` + `hasAPIKey`, it would re-run — rebuilding the whole grouped
  /// setup `Form` — on *every* permission poll tick or key edit, even when
  /// readiness didn't actually flip (e.g. mic granted while Accessibility is still
  /// missing). Recomputing into this stored bool only on a genuine change (see
  /// `syncReadiness`) confines that rebuild to the real wizard→ready transition.
  /// `PermissionsStepView` still observes `permissions` directly for its live rows.
  ///
  /// It doubles as the last-seen readiness edge: overlay visibility is driven by
  /// *transitions* (shown when the app becomes configured, hidden when it stops),
  /// so a steady-state poll never stomps the live recording pill back to idle.
  private(set) var isReady = false

  @ObservationIgnored private weak var coordinator: AppCoordinator?
  /// The API-key surface, observed directly for its `hasAPIKey` readiness input
  /// rather than reached through the coordinator (see `APIKeyModel`). Held
  /// strongly — it's a plain model with no back-reference to this controller, so
  /// there's no retain cycle, and the coordinator that also owns it lives for the
  /// whole app session.
  @ObservationIgnored private let apiKey: APIKeyModel
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var keyObservationTask: Task<Void, Never>?
  /// Brings the setup window forward and activates the app. Invoked when a
  /// previously-configured app loses a requirement (e.g. a revoked permission) so
  /// the user is taken back to onboarding instead of left with a dead overlay.
  @ObservationIgnored private let onNeedsForeground: @MainActor () -> Void
  /// How the live permission status is read. Defaults to the real
  /// `PermissionsChecker`; the UI-test harness injects an all-granted stub so the
  /// ready screen is reachable without the TCC grants the test host can't make.
  @ObservationIgnored private let checkPermissions: () -> PermissionStatus

  init(
    coordinator: AppCoordinator,
    onNeedsForeground: @escaping @MainActor () -> Void,
    checkPermissions: @escaping () -> PermissionStatus = { PermissionsChecker.check() }
  ) {
    self.coordinator = coordinator
    self.apiKey = coordinator.apiKey
    self.onNeedsForeground = onNeedsForeground
    self.checkPermissions = checkPermissions
    self.permissions = checkPermissions()
    // Flips `isReady` to its true value (and shows the overlay if the app is
    // already configured), starting from the `false` default above.
    syncReadiness()
    // React the moment the API key changes, rather than waiting up to a second
    // for the next permission poll, so the overlay appears as soon as the last
    // missing piece is supplied (or hides the instant one is removed).
    observeAPIKeyReadiness()
    // Poll for the app's whole life so a permission revoked while no window is
    // open still kicks the user back into onboarding.
    startPolling()
  }

  /// The live readiness value, computed from the current inputs. Private so only
  /// `syncReadiness` touches the raw `permissions`/`hasAPIKey` — that keeps their
  /// observable dependency off view bodies (the whole point of the stored
  /// `isReady`). The dictation shortcut is *not* part of this gate — it has a
  /// default binding and is rebound in Settings, so a cleared shortcut surfaces as
  /// a hint on the ready screen rather than trapping the user in the wizard.
  private var computedReadiness: Bool {
    permissions.allGranted && apiKey.hasAPIKey
  }

  /// Streams the API-key model's readiness input (`hasAPIKey`) via `Observations`,
  /// which emits after each change commits — no one-shot re-arming (the
  /// pre-macOS-26 `withObservationTracking` fired once, *before* the mutation
  /// committed, and had to re-register after every change). This reveals the
  /// overlay the moment a verified key is saved rather than waiting for the
  /// next permission poll. Idempotent, like `startPolling`.
  private func observeAPIKeyReadiness() {
    keyObservationTask?.cancel()
    let apiKey = apiKey
    let hasAPIKey = Observations { apiKey.hasAPIKey }
    keyObservationTask = Task { @MainActor [weak self] in
      for await _ in hasAPIKey {
        self?.syncReadiness()
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
    let perms = checkPermissions()
    // A permission that was granted and is now gone (revoked in System Settings,
    // possibly while no window was open) should pull the user back into onboarding.
    let revoked = permissions.allGranted && !perms.allGranted
    if perms != permissions {
      permissions = perms
    }
    syncReadiness()
    if revoked { onNeedsForeground() }
  }

  /// Recomputes readiness and, only on a genuine change, updates the observable
  /// `isReady` and drives overlay visibility off the transition. Acting solely on
  /// the edge keeps a steady-state poll tick from re-showing the idle pill over a
  /// live recording — and, because `isReady` is what `MainWindowRoot` observes,
  /// keeps the setup `Form` from rebuilding on non-boundary permission/key
  /// changes. (Pulling the user back into onboarding on a revocation is handled in
  /// `refreshPermissions`, where the cause is known.)
  private func syncReadiness() {
    let ready = computedReadiness
    guard ready != isReady else { return }
    isReady = ready
    if ready {
      coordinator?.showOverlay()
    } else {
      coordinator?.hideOverlay()
    }
  }

  deinit {
    pollTask?.cancel()
    keyObservationTask?.cancel()
  }
}
