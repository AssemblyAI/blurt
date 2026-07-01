import AppKit
import AppUpdater
import BlurtEngine
import OSLog

/// Drives Blurt's self-update via mxcl/AppUpdater.
///
/// AppUpdater ships no UI of its own — it just fetches GitHub Releases, verifies
/// the download was signed by the same Developer ID as the running app, and (on
/// request) swaps the bundle in place and relaunches. So this type supplies the
/// UI: on launch it checks for a newer release of `AssemblyAI/blurt` and, when
/// one exists, presents a Sparkle-style modal offering **Install and Relaunch**
/// or **Later** (mirroring `SPUStandardUserDriver`'s update-available alert).
///
/// The matching asset comes from AppUpdater's convention (`<repo>-<tag>`,
/// case-insensitively): the release pipeline publishes `Blurt-<version>.dmg`,
/// which matches `blurt-<version>`. See `scripts/release-publish.sh`.
@MainActor
final class AutoUpdater {
  private let updater = AppUpdater(owner: "AssemblyAI", repo: "blurt")
  private let log = Logger(subsystem: BlurtIdentity.subsystem, category: "update")

  /// Supplies the window to host the update prompt as a sheet (see `runAlert`).
  /// Injected by `AppDelegate`, which surfaces the main window before returning
  /// it so the prompt isn't stranded behind whatever the user was in. Nil when
  /// the user closed the main window and its recreated scene hasn't
  /// materialized an NSWindow yet — `runAlert` retries a beat later, then falls
  /// back to an app-modal alert rather than crashing.
  private let presentingWindow: @MainActor () -> NSWindow?

  init(presentingWindow: @escaping @MainActor () -> NSWindow?) {
    self.presentingWindow = presentingWindow
  }

  /// Best-effort check. Never throws: any failure (offline, no matching asset,
  /// signature mismatch) is logged and the app keeps running. When an update is
  /// found it prompts; nothing happens silently and the user is never bothered
  /// when already up to date.
  func checkAndPrompt() async {
    do {
      guard let update = try await updater.check() else {
        log.debug("no update available")
        return
      }
      log.notice("update available: \(update.assetName, privacy: .public)")
      await presentUpdatePrompt(for: update)
    } catch {
      log.error("update check failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// The Sparkle-style "a new version is available" alert. **Install and
  /// Relaunch** runs the in-place install (which quits and reopens Blurt);
  /// **Later** dismisses, leaving the next launch to offer it again.
  private func presentUpdatePrompt(for update: Update) async {
    let alert = NSAlert()
    alert.messageText = "A new version of Blurt is available"
    alert.informativeText = updateDescription(for: update)
    alert.addButton(withTitle: "Install and Relaunch")  // default (first button)
    alert.addButton(withTitle: "Later")

    guard await runAlert(alert) == .alertFirstButtonReturn else {
      log.debug("user deferred the update")
      return
    }

    do {
      try await update.installAndRelaunch()
    } catch {
      log.error("update install failed: \(error.localizedDescription, privacy: .public)")
      await presentInstallFailure(error)
    }
  }

  /// Presents `alert` as a sheet on the app's window and awaits the user's
  /// choice. A sheet keeps the main thread on its normal run loop, unlike
  /// `NSAlert.runModal()` — whose nested modal loop blocks the main thread for
  /// as long as the prompt is up and is reported as an app hang. Surfaces the
  /// window first so the sheet (and the app) come forward.
  ///
  /// When no host window exists (the user closed the main window; asking the
  /// scene to recreate it only lands on a later run-loop pass), wait one beat
  /// for that window to materialize, then — in the still-windowless worst case —
  /// fall back to the app-modal `runModal()`: a rare spurious hang report beats
  /// dropping the prompt or crashing.
  private func runAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    var window = presentingWindow()
    if window == nil {
      try? await Task.sleep(for: .milliseconds(100))
      window = presentingWindow()
    }
    guard let window else { return alert.runModal() }
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) { response in
        continuation.resume(returning: response)
      }
    }
  }

  /// "Blurt X is now available—you have Y." Drops the version line if the new
  /// version can't be read from the asset name.
  private func updateDescription(for update: Update) -> String {
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let new = newVersion(fromAssetNamed: update.assetName)
    let lead: String
    switch (new, current) {
    case let (new?, current?): lead = "Blurt \(new) is now available—you have \(current). "
    case let (new?, nil): lead = "Blurt \(new) is now available. "
    default: lead = ""
    }
    return lead + "Would you like to install it now? Blurt will quit and reopen to finish."
  }

  /// Parses the version out of a `Blurt-<version>.dmg` asset name (the part
  /// after the last hyphen, sans extension), or `nil` if it doesn't fit.
  private func newVersion(fromAssetNamed name: String) -> String? {
    let stem = (name as NSString).deletingPathExtension
    guard let version = stem.split(separator: "-").last, !version.isEmpty else { return nil }
    return String(version)
  }

  /// Surfaces a failed install (e.g. the install path wasn't writable) rather
  /// than leaving the user wondering why nothing happened after they clicked.
  private func presentInstallFailure(_ error: Error) async {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Blurt couldn't install the update."
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "OK")
    _ = await runAlert(alert)
  }
}
