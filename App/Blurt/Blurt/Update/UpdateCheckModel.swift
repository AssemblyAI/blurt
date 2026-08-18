import AppKit
import BlurtEngine
import OSLog
import Observation

/// Runs an update check and reports the result in a modal alert (Sparkle-style).
/// One shared instance (owned by `AppDelegate`) backs every entry point, so no
/// two checks can stack two result alerts. Two kinds of check:
///
/// - **User-initiated** — `checkForUpdates()`, from the Settings "Check for
///   Updates" button or the "Check for Updates…" app-menu command. Always
///   reports something, including "you're up to date" and "couldn't check": the
///   user asked, so the check has to visibly conclude.
/// - **Automatic at launch** — `checkForUpdatesAtLaunch(isConfigured:)`, once per
///   launch on a configured app and at most once a day, speaking *only* when a
///   newer release exists. Nobody launches Blurt to be told it's current, and a
///   laptop opened offline mustn't be greeted by an error it never asked for.
///
/// Neither installs anything. On an available update the alert offers
/// **Download** (opens the release DMG in the browser) or **Later**.
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
  /// When a check last completed, the input to the launch check's daily
  /// throttle. Written by every completed check — manual ones included, so a
  /// check the user just ran isn't repeated by the next launch.
  private let lastCheckStore: LastUpdateCheckStore
  /// The clock, injected alongside the store so the throttle is drivable in a
  /// test without waiting a day.
  private let now: () -> Date
  private let log = HostIdentity.current.logger("update")

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

  /// Every collaborator is injected (with sensible production defaults) so this
  /// stays exercisable without a real bundle, a live browser, an on-screen
  /// window, the user's defaults, or the wall clock.
  init(
    checker: UpdateChecker = UpdateChecker(),
    currentVersion: SemanticVersion? = UpdateCheckModel.bundleVersion(),
    openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) },
    presentingWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
    lastCheckStore: LastUpdateCheckStore = LastUpdateCheckStore(),
    now: @escaping () -> Date = { Date() }
  ) {
    self.checker = checker
    self.currentVersion = currentVersion
    self.openURL = openURL
    self.presentingWindow = presentingWindow
    self.lastCheckStore = lastCheckStore
    self.now = now
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

  /// The automatic check, run once from `applicationDidFinishLaunching` on a
  /// configured app. Whether it runs at all — setup finished, and a day since the
  /// last completed check — is the engine's `AutomaticUpdateCheck.shouldRun`.
  ///
  /// Deliberately quieter than the manual path: it alerts only on an available
  /// update. "Up to date" and "couldn't check" answer a question the user didn't
  /// ask, and a modal at launch saying either one is a nuisance (offline, on a
  /// plane, GitHub down). They still log, and the menu command still reports
  /// them on demand.
  func checkForUpdatesAtLaunch(isConfigured: Bool) {
    // Cheap early-out so a launch that clearly isn't due spawns nothing. The
    // decision is made again after the wait, where it's authoritative.
    guard isLaunchCheckDue(isConfigured: isConfigured) else { return }
    // No parseable bundle version means no check to run. The manual path turns
    // that into an alert because someone is waiting on an answer; here nobody is.
    guard currentVersion != nil else {
      log.error("no parseable CFBundleShortVersionString; skipping the launch update check")
      return
    }
    Task {
      // Let the launch settle before fetching, and give the main window time to
      // exist so a result has a sheet host — see `AutomaticUpdateCheck.launchDelay`.
      try? await Task.sleep(for: AutomaticUpdateCheck.launchDelay)
      // Everything is re-read after the wait, because the user can act during it:
      // `isChecking` catches a manual check still in flight (two would stack two
      // alerts), and the throttle catches one that *completed* here — it stamped
      // the store, so this launch has its answer already and fetching again would
      // be a redundant request and possibly a second alert.
      guard !isChecking, isLaunchCheckDue(isConfigured: isConfigured), let currentVersion else { return }
      isChecking = true
      defer { isChecking = false }
      guard let result = await runCheck(current: currentVersion) else { return }
      // Which results are worth interrupting an unprompted launch for is the
      // engine's `forUnpromptedCheck` (nil = log only), so this path can't disagree
      // with the wording — or quietly drop a result added later.
      guard
        let content = UpdateAlertContent.forUnpromptedCheck(
          result: result, current: currentVersion)
      else { return }
      await present(content)
    }
  }

  /// The launch gate, read fresh each time: the stored stamp moves whenever any
  /// check completes, so this can flip between the call and the post-delay
  /// re-check. `isConfigured` is the caller's (the wizard's readiness at launch),
  /// which is why it's passed through rather than captured here.
  private func isLaunchCheckDue(isConfigured: Bool) -> Bool {
    AutomaticUpdateCheck.shouldRun(isConfigured: isConfigured, lastCheck: lastCheckStore.lastCheck, now: now())
  }

  /// Runs the check and resolves what to show. Every throw — offline, GitHub
  /// unreachable, malformed JSON, an unparseable tag — is the same recoverable
  /// "couldn't check" to the user, so they collapse to one content value here.
  private func resolveContent(current: SemanticVersion) async -> UpdateAlertContent {
    guard let result = await runCheck(current: current) else { return .checkFailed }
    return UpdateAlertContent(result: result, current: current)
  }

  /// Performs the check and stamps the throttle, returning `nil` when it threw
  /// (the callers differ only in whether they say so out loud).
  ///
  /// Only a *completed* check is stamped: a failed one never answered the
  /// question, so the next launch should ask again rather than coast for a day
  /// on a fetch that never landed. A successful manual check is stamped too —
  /// the launch check has nothing to add the morning after the user looked.
  private func runCheck(current: SemanticVersion) async -> UpdateCheckResult? {
    do {
      let result = try await checker.check(current: current)
      lastCheckStore.lastCheck = now()
      return result
    } catch {
      log.error("update check failed: \(error.localizedDescription, privacy: .public)")
      return nil
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
