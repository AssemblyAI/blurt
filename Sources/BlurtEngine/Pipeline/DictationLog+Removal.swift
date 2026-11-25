import Foundation
import os

// The reset half of the developer-mode log: deleting what it wrote. Split from
// `DictationLog.swift` by topic, as the errors and commands halves are.
extension DictationLog {
  /// Deletes both halves of the developer-mode log — the transcript corpus and
  /// the sibling error log — and the directory they share once it's empty. The
  /// file half of a full reset (`InstallReset`), matching what
  /// `scripts/reset-lib.sh` removes: a preinstall state has neither file,
  /// and the logs are the one place transcripts are written to disk, so leaving
  /// them behind would be the most sensitive half of the reset going undone.
  ///
  /// A file that isn't there is a success, not a failure — that's the state
  /// being asked for, and it's the normal case for anyone who never switched
  /// developer mode on. False means a file exists and couldn't be removed.
  ///
  /// The directory removal is deliberately conditional on it being empty: it is
  /// `~/Library/Logs/<host>`, and anything else that ended up there is not this
  /// function's to delete.
  ///
  /// Internal, like every other step of the sweep: `InstallReset` is the door
  /// the shell uses, so this needs no more reach than the engine itself.
  @discardableResult
  static func removeStoredLogs() -> Bool {
    removeStoredLogs(dictations: defaultURL, errors: defaultErrorURL, commands: defaultCommandURL)
  }

  /// The addressable half of `removeStoredLogs()`, taking every URL for the
  /// reason `append` takes one: otherwise the only way to exercise this is
  /// against the developer's real `~/Library/Logs`. No defaults: one on
  /// `commands` had every test that named the other two delete the real
  /// command log, each `swift test` (2026-11-04).
  @discardableResult
  static func removeStoredLogs(dictations: URL, errors: URL, commands: URL) -> Bool {
    let manager = FileManager.default
    var allRemoved = true
    for url in [dictations, errors, commands] where manager.fileExists(atPath: url.path(percentEncoded: false)) {
      do {
        try manager.removeItem(at: url)
      } catch {
        allRemoved = false
        // The name only, never the absolute path — it carries the user's account
        // name, and this is the system-wide log.
        let reason = error.localizedDescription
        logger.error(
          "removing \(url.lastPathComponent, privacy: .public) failed: \(reason, privacy: .public)"
        )
      }
    }
    let directory = dictations.deletingLastPathComponent()
    let remaining = try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
    if remaining?.isEmpty == true {
      try? manager.removeItem(at: directory)
    }
    return allRemoved
  }
}
