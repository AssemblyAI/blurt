import AppKit
import BlurtEngine
import OSLog
import SwiftUI

/// The Advanced pane's developer-mode switch.
///
/// Developer mode is an opt-in: while on, every completed dictation is appended
/// to the local JSONL log and every failed one to a sibling error log (see
/// `DictationLog` — both gates read the same default this toggle writes), and
/// the section grows a "Show Logs in Finder" row and a footer naming where the
/// logs live.
struct MaintenanceSection: View {
  @AppStorage(DeveloperModeStore.defaultsKey)
  private var developerMode = false

  var body: some View {
    Section {
      Toggle(isOn: $developerMode) {
        SettingLabel(
          title: "Developer mode",
          systemImage: "hammer",
          subtitle: "Keep local logs of dictations and failures."
        )
      }
      .accessibilityIdentifier(UITestIdentifiers.developerToggle)
      if developerMode {
        SettingRow(title: "Logs", systemImage: "doc.text.magnifyingglass") {
          Button("Show in Finder", action: showLogs)
            .accessibilityIdentifier(UITestIdentifiers.developerShowLogs)
        }
      }
    } footer: {
      if developerMode {
        // Both home-abbreviated paths are derived in the engine next to the URLs
        // the writers append to, so this label can never drift from where the
        // logs actually land. No trailing period: a path ends the line, so it
        // can be selected and copied without picking up punctuation — which is
        // also why the first path is followed by a plain space, not a comma.
        Text(
          "Logs each dictation to \(DictationLog.defaultDisplayPath), "
            + "each \(KeyActionName.command) command to \(DictationLog.defaultCommandDisplayPath) "
            + "and each failure to \(DictationLog.defaultErrorDisplayPath)"
        )
        .textSelection(.enabled)
      }
    }
  }

  /// Reveals the dictation log in Finder, selected in its folder, as "Show in
  /// Finder" does everywhere. Before the first entry lands there is no file to
  /// select, and a button that silently did nothing right after the switch went
  /// on would read as broken — so the directory is created if need be and
  /// opened instead (the reset sweep removes it again once it's empty).
  private func showLogs() {
    let log = DictationLog.defaultURL
    if FileManager.default.fileExists(atPath: log.path(percentEncoded: false)) {
      NSWorkspace.shared.activateFileViewerSelecting([log])
      return
    }
    let directory = log.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    NSWorkspace.shared.open(directory)
  }
}
