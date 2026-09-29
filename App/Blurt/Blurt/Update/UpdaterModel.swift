import BlurtEngine
import Foundation
import Observation
import Sparkle

/// Blurt's updater: a thin `@Observable` face on Sparkle's standard controller.
/// One shared instance (owned by `AppDelegate`) backs every entry point — the
/// "Check for Updates…" app-menu command, the menu-bar item, and the Settings
/// Updates row — so they all drive the one `SPUUpdater`.
///
/// Sparkle owns everything past the button: the scheduled background check
/// (daily, per `SUScheduledCheckInterval`), the "you're up to date" /
/// "a new version is available" UI, downloading the DMG from the appcast,
/// verifying its EdDSA signature against `SUPublicEDKey`, and replacing the app
/// in place. The feed and key live in `Info.plist` (see `project.yml`); the
/// release pipeline publishes the signed `appcast.xml` next to the DMG (see
/// RELEASE.md).
///
/// **Only the shipping build starts the updater.** "Blurt Dev" is a separate app
/// (`dev.alex.blurt.dev`) installed at a separate path, and the appcast
/// describes the *release* — letting Sparkle run would offer to overwrite a dev
/// build with a shipped one. With the updater unstarted, `canCheckForUpdates`
/// stays false, so every entry point is disabled rather than silently inert.
/// Decided from the running bundle id, not `#if DEBUG`, for the reason
/// `BlurtApp.init` picks the host identity that way: the id is what makes the two
/// apps different to macOS, so a configuration added later can't start updating
/// itself because someone forgot a compilation condition.
@MainActor
@Observable
final class UpdaterModel {
  @ObservationIgnored private let controller: SPUStandardUpdaterController
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []

  /// Whether a user-initiated check can start right now. False while one is
  /// already in flight (Sparkle is showing its own progress UI) and always false
  /// when the updater was never started (debug builds). Mirrored from Sparkle's
  /// KVO-observable property so SwiftUI can disable the buttons.
  private(set) var canCheckForUpdates = false

  /// Whether this build runs the updater at all — false in debug builds, where
  /// the Settings row says so instead of offering controls that do nothing.
  let isEnabled: Bool

  /// Title of the Settings "Updates" row, e.g. "Blurt 0.1.31".
  let versionLabel: String

  init() {
    isEnabled = Self.startsUpdater
    controller = SPUStandardUpdaterController(
      startingUpdater: isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
    versionLabel = Self.bundleVersionLabel()
    // Sparkle publishes these on the main thread. The two preferences are read
    // live from Sparkle, so their observers only invalidate: Sparkle's own update
    // alert can flip "install automatically", and an open Settings pane should
    // show it.
    let updater = controller.updater
    observations = [
      updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] observed, _ in
        MainActor.assumeIsolated { self?.canCheckForUpdates = observed.canCheckForUpdates }
      },
      updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.withMutation(keyPath: \.automaticallyChecksForUpdates) {} }
      },
      updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.withMutation(keyPath: \.automaticallyDownloadsUpdates) {} }
      },
    ]
  }

  /// Runs a user-initiated check; Sparkle presents the result either way.
  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }

  /// The "check automatically" preference. Sparkle persists it in the app's
  /// defaults; it starts on because `SUEnableAutomaticChecks` is set in
  /// `Info.plist`, which also suppresses Sparkle's second-launch permission
  /// prompt.
  var automaticallyChecksForUpdates: Bool {
    get {
      access(keyPath: \.automaticallyChecksForUpdates)
      return controller.updater.automaticallyChecksForUpdates
    }
    set {
      withMutation(keyPath: \.automaticallyChecksForUpdates) {
        controller.updater.automaticallyChecksForUpdates = newValue
      }
    }
  }

  /// The "download and install automatically" preference. Off by default: a
  /// found update is offered, and installed only when the user says so.
  var automaticallyDownloadsUpdates: Bool {
    get {
      access(keyPath: \.automaticallyDownloadsUpdates)
      return controller.updater.automaticallyDownloadsUpdates
    }
    set {
      withMutation(keyPath: \.automaticallyDownloadsUpdates) {
        controller.updater.automaticallyDownloadsUpdates = newValue
      }
    }
  }

  /// The shipping build updates itself; debug builds (Blurt Dev, the UI-test
  /// build) never do — see the type comment.
  private static var startsUpdater: Bool {
    Bundle.main.bundleIdentifier == HostIdentity.blurt.subsystem
  }

  private static func bundleVersionLabel() -> String {
    let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Blurt"
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else { return name }
    return "\(name) \(version)"
  }
}
