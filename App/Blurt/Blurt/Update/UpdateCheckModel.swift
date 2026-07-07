import AppKit
import BlurtEngine
import OSLog
import Observation

/// Drives the Settings "Check for Update" button. Replaces the old launch-time
/// `AutoUpdater`: no in-place install and no relaunch — a successful check
/// either reports the app is current or hands back a DMG URL the user opens in
/// the browser. All failures collapse to `.failed` (one inline caption); the
/// user just clicks again.
@MainActor
@Observable
final class UpdateCheckModel {
  enum State {
    case idle
    case checking
    case upToDate(String)
    case available(version: String, dmgURL: URL)
    case failed
  }

  private(set) var state: State = .idle

  private let checker: UpdateChecker
  private let currentVersion: SemanticVersion?
  private let openURL: (URL) -> Void
  private let log = Logger(subsystem: BlurtIdentity.subsystem, category: "update")

  /// `currentVersion` and `openURL` are injected (defaulting to the bundle's
  /// version and `NSWorkspace`) so this stays exercisable without a real bundle
  /// or a live browser.
  init(
    checker: UpdateChecker = UpdateChecker(),
    currentVersion: SemanticVersion? = UpdateCheckModel.bundleVersion(),
    openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
  ) {
    self.checker = checker
    self.currentVersion = currentVersion
    self.openURL = openURL
  }

  /// Runs a check and publishes the result. A missing/unparseable bundle
  /// version can't be compared, so it fails the same as a network error.
  func check() async {
    guard let currentVersion else {
      log.error("no parseable CFBundleShortVersionString; can't check for updates")
      state = .failed
      return
    }
    state = .checking
    do {
      switch try await checker.check(current: currentVersion) {
      case .upToDate(let current):
        state = .upToDate(current.description)
      case .available(let version, let dmgURL):
        state = .available(version: version.description, dmgURL: dmgURL)
      }
    } catch {
      log.error("update check failed: \(error.localizedDescription, privacy: .public)")
      state = .failed
    }
  }

  /// Opens the release DMG in the browser. No-op unless an update is available.
  func download() {
    guard case .available(_, let dmgURL) = state else { return }
    openURL(dmgURL)
  }

  private static func bundleVersion() -> SemanticVersion? {
    let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return raw.flatMap(SemanticVersion.init)
  }
}
