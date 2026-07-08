import AppKit
import BlurtEngine
import OSLog

/// Runs a user-initiated update check and reports the result in a modal alert
/// (Sparkle-style). Triggered from either the Settings "Check for Updates"
/// button or the "Check for Updates…" app-menu command — a single shared
/// instance backs both (owned by `AppDelegate`). No in-place install: on an
/// available update the alert offers **Download** (opens the release DMG in the
/// browser) or **Later**.
@MainActor
final class UpdateCheckModel {
  private let checker: UpdateChecker
  private let currentVersion: SemanticVersion?
  private let openURL: (URL) -> Void
  private let presentingWindow: () -> NSWindow?
  private let log = Logger(subsystem: BlurtIdentity.subsystem, category: "update")

  /// Guards against a second check while one is in flight (double-click, or the
  /// button and menu both fired), so we never stack two result alerts.
  private var isChecking = false

  /// The running app version for display in the Settings "Updates" section
  /// (nil when the bundle version can't be parsed), e.g. "0.1.31".
  var currentVersionText: String? { currentVersion.map { "\($0)" } }

  /// `currentVersion`, `openURL`, and `presentingWindow` are injected (with
  /// sensible production defaults) so this stays exercisable without a real
  /// bundle, a live browser, or an on-screen window.
  init(
    checker: UpdateChecker = UpdateChecker(),
    currentVersion: SemanticVersion? = UpdateCheckModel.bundleVersion(),
    openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
    presentingWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }
  ) {
    self.checker = checker
    self.currentVersion = currentVersion
    self.openURL = openURL
    self.presentingWindow = presentingWindow
  }

  /// Checks GitHub and reports the result in a modal alert. Safe to call from
  /// the app menu and the menu-bar item; a check already in flight is ignored.
  func checkForUpdates() {
    guard !isChecking else { return }
    guard let currentVersion else {
      log.error("no parseable CFBundleShortVersionString; can't check for updates")
      Task { await presentFailure() }
      return
    }
    isChecking = true
    Task {
      defer { isChecking = false }
      do {
        switch try await checker.check(current: currentVersion) {
        case .upToDate:
          await presentUpToDate(current: currentVersion)
        case .available(let version, let dmgURL):
          await presentAvailable(current: currentVersion, version: version, dmgURL: dmgURL)
        }
      } catch {
        log.error("update check failed: \(error.localizedDescription, privacy: .public)")
        await presentFailure()
      }
    }
  }

  /// "You're up to date" — the reassuring result the classic updater shows so a
  /// user-initiated check always visibly confirms it ran.
  private func presentUpToDate(current: SemanticVersion) async {
    let alert = NSAlert()
    alert.messageText = "You’re up to date"
    alert.informativeText = "Blurt \(current) is the latest version."
    alert.addButton(withTitle: "OK")
    _ = await runAlert(alert)
  }

  /// "A new version is available" — **Download** (default) opens the release DMG
  /// in the browser; **Later** dismisses. `current` is the running version the
  /// check compared against (always known by the time we get here).
  private func presentAvailable(current: SemanticVersion, version: SemanticVersion, dmgURL: URL) async {
    let alert = NSAlert()
    alert.messageText = "A new version of Blurt is available"
    alert.informativeText = "Blurt \(version) is available—you have \(current). Download it now?"
    alert.addButton(withTitle: "Download")  // default (first button)
    alert.addButton(withTitle: "Later")
    if await runAlert(alert) == .alertFirstButtonReturn {
      openURL(dmgURL)
    }
  }

  /// A recoverable "couldn't check" result (offline, GitHub unreachable, a
  /// malformed response). The user just tries again.
  private func presentFailure() async {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Couldn’t check for updates"
    alert.informativeText = "Check your internet connection and try again."
    alert.addButton(withTitle: "OK")
    _ = await runAlert(alert)
  }

  /// Presents `alert` as a sheet on the host window and awaits the choice. A
  /// sheet keeps the main thread on its run loop, unlike `runModal()`'s nested
  /// modal loop (reported as an app hang). Falls back to `runModal()` only when
  /// no window can host a sheet (e.g. the menu command fired with every window
  /// closed) — a rare spurious hang beats dropping the result.
  private func runAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    guard let window = presentingWindow() else { return alert.runModal() }
    return await withCheckedContinuation { continuation in
      alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
    }
  }

  private static func bundleVersion() -> SemanticVersion? {
    let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return raw.flatMap(SemanticVersion.init)
  }
}
