import BlurtEngine
import SwiftUI

/// The permission sections of the setup/settings screen: Microphone and
/// Accessibility. Each row shows "Granted" once the grant lands, or an action
/// button that opens the relevant flow. There's no "Continue" — the screen is a
/// single page, so the rows simply reflect live status (the controller polls
/// while the window is open).
struct PermissionsStepView: View {
  var controller: WizardController

  /// Observed rather than read once via `TriggerKeyStore()`: Settings is reachable
  /// with ⌘, while this page is showing, so a one-shot read left the footer naming
  /// the old key after a rebind until something else re-rendered the view. Same
  /// `ObservedKeyBindings` as `ReadyView` / `MenuBarScene`.
  @ObservedKeyBindings private var bindings
  private var triggerKey: TriggerKey { bindings.bound }

  /// Set when the user taps a settings button so the section can show a
  /// "waiting for you to come back" cue until the poll sees the grant.
  @State private var openedAccessibilitySettings = false
  /// Same cue for Microphone, set when the in-app prompt couldn't grant access
  /// and we fell back to opening System Settings.
  @State private var openedMicrophoneSettings = false
  /// Set when the Accessibility grant is still outstanding well after the user
  /// opened System Settings — the signature of a grant pinned to a stale signing
  /// identity, where the toggle shows on while `AXIsProcessTrusted()` stays
  /// false (see AGENTS.md, "The Accessibility grant and signing identity").
  /// Relaunching runs the launch-time self-heal, so the footer says so.
  @State private var accessibilityGrantLooksStuck = false

  /// How long the grant stays outstanding after opening System Settings before
  /// the footer suggests a relaunch. Long enough to find and flip the toggle.
  private static let stuckGrantHintDelay: Duration = .seconds(12)

  var body: some View {
    Section("Permissions") {
      microphoneSection
      accessibilitySection
    }
  }

  private var microphoneSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      permissionRow(
        PermissionInfo(
          label: "Microphone", symbol: "mic.fill", buttonLabel: "Allow Access",
          detail: "Records when you use \(triggerKey.keycapLabel)."),
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
      settingsFooter(
        opened: openedMicrophoneSettings,
        granted: controller.permissions.microphone,
        waiting: "Waiting for you to turn on Blurt under Microphone…"
      )
    }
  }

  private var accessibilitySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      permissionRow(
        PermissionInfo(
          label: "Accessibility", symbol: "accessibility", buttonLabel: "Open Settings…",
          detail: "Pastes dictations into the active app."),
        granted: controller.permissions.accessibility,
        action: {
          openedAccessibilitySettings = true
          PermissionsChecker.openAccessibilitySettings()
        }
      )
      VStack(alignment: .leading, spacing: 4) {
        settingsFooter(
          opened: openedAccessibilitySettings,
          granted: controller.permissions.accessibility,
          waiting: "Waiting for you to turn on Blurt in the Accessibility list…"
        )
        if accessibilityGrantLooksStuck && openedAccessibilitySettings
          && !controller.permissions.accessibility
        {
          Text("If the Blurt toggle is already on, quit and reopen Blurt to refresh the grant.")
        }
      }
      // Arms the stuck cue once the user heads to System Settings; if the grant
      // lands first, the condition above keeps the line hidden.
      .task(id: openedAccessibilitySettings) {
        guard openedAccessibilitySettings else { return }
        try? await Task.sleep(for: Self.stuckGrantHintDelay)
        // The sleep swallows cancellation (`try?`), so check it explicitly —
        // a cancelled arm (view gone, id flipped back) must not set the flag.
        guard !Task.isCancelled else { return }
        accessibilityGrantLooksStuck = true
      }
      // A grant that lands retires both cues: if the user later revokes it with
      // the wizard still open, the footer should re-arm from a fresh settings
      // tap rather than show the relaunch hint instantly with stale advice.
      .onChange(of: controller.permissions.accessibility) {
        guard controller.permissions.accessibility else { return }
        openedAccessibilitySettings = false
        accessibilityGrantLooksStuck = false
      }
    }
  }

  /// Shared footer for a settings-backed permission row: a "waiting for you to
  /// come back" cue while the grant is outstanding after the user opened
  /// Settings. The explanation stays beneath the row title.
  @ViewBuilder
  private func settingsFooter(opened: Bool, granted: Bool, waiting: String)
    -> some View
  {
    if opened && !granted {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(waiting)
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
  }

  /// Static descriptors for a permission row, bundled so `permissionRow` stays
  /// within the parameter-count limit.
  private struct PermissionInfo {
    let label: String
    let symbol: String
    let buttonLabel: String
    let detail: String
  }

  @ViewBuilder
  private func permissionRow(
    _ info: PermissionInfo,
    granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    SettingRow(title: info.label, systemImage: info.symbol, subtitle: info.detail) {
      if granted {
        HStack(spacing: 4) {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(BlurtBrand.accent)
          Text("Granted").foregroundStyle(.secondary)
        }
      } else {
        Button(info.buttonLabel, action: action)
          .glassButtonStyleCompat(prominent: false)
          .accessibilityLabel("\(info.label): \(info.buttonLabel)")
      }
    }
  }
}
