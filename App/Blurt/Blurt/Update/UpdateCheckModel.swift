import AppKit
import BlurtEngine
import OSLog
import Observation

/// Runs a user-initiated update check and reports the result in a modal alert
/// (Sparkle-style). Triggered from either the Settings "Check for Updates"
/// button or the "Check for Updates…" app-menu command — a single shared
/// instance backs both (owned by `AppDelegate`). No in-place install: on an
/// available update the alert offers **Download** (opens the release DMG in the
/// browser) or **Later**.
///
/// What each result *says* — titles, bodies, button titles, and which button
/// downloads — is the engine's `UpdateAlertContent`, where `swift test` covers
/// it. What's left here is the AppKit half: turning a content value into an
/// `NSAlert`, hosting it as a sheet, and opening the URL the default button
/// carries.
@MainActor
@Observable
final class UpdateCheckModel {
  private let checker: UpdateChecker
  private let currentVersion: SemanticVersion?
  private let openURL: (URL) -> Void
  private let presentingWindow: () -> NSWindow?
  private let log = Logger(subsystem: BlurtIdentity.subsystem, category: "update")

  /// Guards against a second check while one is in flight (double-click, or the
  /// button and menu both fired), so we never stack two result alerts. Observable
  /// so the Settings "Check for Updates" button can show a spinner and disable
  /// itself while a check runs — the feedback a slow connection otherwise lacks.
  private(set) var isChecking = false

  /// Title of the Settings "Updates" row, e.g. "Blurt 0.1.31" — or just "Blurt"
  /// when the bundle version can't be parsed (the button still works; the check
  /// reads the version itself). The wording is the engine's, shared with the
  /// alerts, so the row and the "you have …" line can't name the version two
  /// different ways.
  var versionLabel: String { UpdateAlertContent.appVersionLabel(currentVersion) }

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
      // Indistinguishable from any other failed check as far as the user is
      // concerned — which is why it shares the one `.checkFailed` content
      // rather than a second hand-rolled alert.
      Task { await present(.checkFailed) }
      return
    }
    isChecking = true
    Task {
      defer { isChecking = false }
      await present(await resolveContent(current: currentVersion))
    }
  }

  /// Runs the check and resolves what to show. Every throw — offline, GitHub
  /// unreachable, malformed JSON, an unparseable tag — is the same recoverable
  /// "couldn't check" to the user, so they collapse to one content value here.
  private func resolveContent(current: SemanticVersion) async -> UpdateAlertContent {
    do {
      return UpdateAlertContent(result: try await checker.check(current: current), current: current)
    } catch {
      log.error("update check failed: \(error.localizedDescription, privacy: .public)")
      return .checkFailed
    }
  }

  /// Presents `content` as an alert and performs its default action. The only
  /// judgement left here is AppKit-shaped: the *first* button is the default, so
  /// that response — and only when the content carries a URL — is the download.
  private func present(_ content: UpdateAlertContent) async {
    let alert = NSAlert()
    alert.messageText = content.title
    alert.informativeText = content.message
    // `NSAlert` already defaults to `.warning`, and on current macOS `.warning`
    // and `.informational` render identically (only `.critical` adds the caution
    // badge), so only the caution case is worth stating — same presentation the
    // three hand-built alerts had.
    if content.style == .warning { alert.alertStyle = .warning }
    for title in content.buttons {
      alert.addButton(withTitle: title)  // first added is the default button
    }
    if await runAlert(alert) == .alertFirstButtonReturn, let dmgURL = content.downloadURL {
      openURL(dmgURL)
    }
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
