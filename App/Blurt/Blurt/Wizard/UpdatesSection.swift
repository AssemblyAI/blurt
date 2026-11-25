import OSLog
import SwiftUI

// The Advanced pane's four sections: updates (version, check, Sparkle's two
// preferences), developer mode, the experimental switches, and the start-over button. All are
// Settings-only (none gates setup, so none is a wizard step), and they live here
// rather than in `SettingsWindowRoot` because that file is at the repo's
// file-length limit.

/// The running version, a "Check for Updates…" button, and Sparkle's two
/// preferences. Every control drives the one `UpdaterModel` owned by
/// `AppDelegate` — the same updater the app-menu command and the menu-bar item
/// use — and Sparkle presents the check's progress and result itself.
///
/// In a debug build the updater never starts (see `UpdaterModel`), so the
/// controls are disabled and the footer says why rather than leaving a button
/// that silently does nothing.
struct UpdatesSection: View {
  @Bindable var model: UpdaterModel

  var body: some View {
    Section {
      // Ellipsis: it opens Sparkle's window, where an update still waits on the
      // user's go-ahead — the same rule as "Reset…" below.
      SettingRow(title: "Version", systemImage: "info.circle", subtitle: model.versionLabel) {
        Button("Check for Updates…") { model.checkForUpdates() }
          .disabled(!model.canCheckForUpdates)
          .accessibilityIdentifier(UITestIdentifiers.updateCheck)
      }
      Toggle(isOn: $model.automaticallyChecksForUpdates) {
        SettingLabel(
          title: "Automatic checks",
          systemImage: "clock",
          subtitle: "Check for new versions in the background."
        )
      }
      .disabled(!model.isEnabled)
      .accessibilityIdentifier(UITestIdentifiers.updateAutoCheck)
      // Installing on its own only means anything while Blurt is looking on its
      // own, so the second switch follows the first.
      Toggle(isOn: $model.automaticallyDownloadsUpdates) {
        SettingLabel(
          title: "Automatic installation",
          systemImage: "arrow.down.circle",
          subtitle: "Download and install new versions automatically."
        )
      }
      .disabled(!model.isEnabled || !model.automaticallyChecksForUpdates)
    } header: {
      Text("Updates")
    } footer: {
      if !model.isEnabled {
        Text("This development build doesn’t update itself.")
      }
    }
  }
}
