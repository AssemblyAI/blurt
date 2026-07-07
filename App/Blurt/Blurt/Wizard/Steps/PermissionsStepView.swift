import BlurtEngine
import SwiftUI

/// The permission sections of the setup/settings screen: Microphone and
/// Accessibility. Each row shows "Granted" once the grant lands, or an action
/// button that opens the relevant flow. There's no "Continue" — the screen is a
/// single page, so the rows simply reflect live status (the controller polls
/// while the window is open).
struct PermissionsStepView: View {
  var controller: WizardController

  /// Set when the user taps a settings button so the section can show a
  /// "waiting for you to come back" cue until the poll sees the grant.
  @State private var openedAccessibilitySettings = false
  /// Same cue for Microphone, set when the in-app prompt couldn't grant access
  /// and we fell back to opening System Settings.
  @State private var openedMicrophoneSettings = false

  var body: some View {
    Group {
      microphoneSection
      accessibilitySection
    }
  }

  private var microphoneSection: some View {
    Section {
      permissionRow(
        PermissionInfo(label: "Microphone", symbol: "mic.fill", buttonLabel: "Allow Microphone Access"),
        granted: controller.permissions.microphone,
        action: {
          Task {
            let granted = await PermissionsChecker.requestMicrophone()
            controller.refreshPermissions()
            // The in-app prompt only appears while the status is undetermined;
            // once the user has declined (or the system won't present it) the
            // button would otherwise do nothing. Fall back to System Settings so
            // the row always makes progress, like the Accessibility row.
            if !granted {
              openedMicrophoneSettings = true
              PermissionsChecker.openMicrophoneSettings()
            }
          }
        }
      )
    } header: {
      Text("Permissions")
    } footer: {
      settingsFooter(
        opened: openedMicrophoneSettings,
        granted: controller.permissions.microphone,
        waiting: "Waiting for you to turn on Blurt under Microphone…",
        description: "Blurt records only after you start dictating with \(DictateHotkey.label)."
      )
    }
  }

  private var accessibilitySection: some View {
    Section {
      permissionRow(
        PermissionInfo(
          label: "Accessibility", symbol: "accessibility", buttonLabel: "Open Accessibility Settings…"),
        granted: controller.permissions.accessibility,
        action: {
          openedAccessibilitySettings = true
          PermissionsChecker.openAccessibilitySettings()
        }
      )
    } footer: {
      settingsFooter(
        opened: openedAccessibilitySettings,
        granted: controller.permissions.accessibility,
        waiting: "Waiting for you to turn on Blurt in the Accessibility list…",
        description: "Blurt uses Accessibility to paste transcripts into the active app."
      )
    }
  }

  /// Shared footer for a settings-backed permission row: a "waiting for you to
  /// come back" cue while the grant is outstanding after the user opened
  /// Settings, otherwise the explanatory description.
  @ViewBuilder
  private func settingsFooter(opened: Bool, granted: Bool, waiting: String, description: String)
    -> some View
  {
    if opened && !granted {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(waiting)
      }
    } else {
      Text(description)
    }
  }

  /// Static descriptors for a permission row, bundled so `permissionRow` stays
  /// within the parameter-count limit.
  private struct PermissionInfo {
    let label: String
    let symbol: String
    let buttonLabel: String
  }

  @ViewBuilder
  private func permissionRow(
    _ info: PermissionInfo,
    granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    // Plain HStack (default `.center` vertical alignment) rather than
    // `LabeledContent`, which baseline-aligns the label to the control and
    // leaves the button reading slightly high — matches the other settings/setup
    // rows (see `PickerSettingRow`, `APIKeyStepView.savedRow`).
    HStack {
      Label(info.label, systemImage: info.symbol)
      Spacer(minLength: 12)
      if granted {
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
          Text("Granted").foregroundStyle(.secondary)
        }
      } else {
        Button(info.buttonLabel, action: action)
      }
    }
  }
}
