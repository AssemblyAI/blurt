import BlurtEngine
import SwiftUI

/// Root view of the `Settings` scene. A `TabView` at the root of a `Settings`
/// scene renders as the standard macOS preferences window — a segmented toolbar
/// of panes (General / Advanced), each sized to its own content. This is the
/// HIG-native answer to a settings screen that outgrows one pane: keeping every
/// pane short means the window never has to grow past a small display (a single
/// stacked `Form` did, stranding the bottom section off-screen). Each pane
/// reuses the same section views the wizard's setup step uses, so the two stay
/// in sync.
struct SettingsWindowRoot: View {
  var appDelegate: AppDelegate

  private enum Tab: Hashable { case general, advanced }

  /// Drives the selected pane from `@State` (not the OS's persisted preference
  /// tab), so the window always opens on General. Without an explicit binding
  /// macOS restores the last-used pane across launches, which retitles the
  /// window ("General" → "Advanced") and made the settings window unfindable in
  /// UI tests from one run to the next.
  @State private var tab: Tab = .general

  var body: some View {
    if let coordinator = appDelegate.coordinator {
      TabView(selection: $tab) {
        GeneralSettingsTab(coordinator: coordinator)
          .tabItem { Label(UITestIdentifiers.generalSettingsTab, systemImage: "gearshape") }
          .tag(Tab.general)
        AdvancedSettingsTab(updateModel: appDelegate.updateCheckModel)
          .tabItem { Label(UITestIdentifiers.advancedSettingsTab, systemImage: "gearshape.2") }
          .tag(Tab.advanced)
      }
      .frame(width: 480)
    } else {
      Color.clear.frame(width: 480, height: 240)
    }
  }
}

/// The chrome every settings pane shares: a grouped, non-scrolling `Form` that
/// hugs its content, so each pane sizes the window to exactly its sections and
/// the panes can't drift apart in layout.
private struct SettingsPane<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// The everyday setup a user changes: the AssemblyAI key, the dictation
/// shortcut, the cue sound, and the transcription key terms.
private struct GeneralSettingsTab: View {
  let coordinator: AppCoordinator

  var body: some View {
    SettingsPane {
      APIKeyStepView(apiKey: coordinator.apiKey)
      HotkeyStepView(coordinator: coordinator)
      SoundStepView(coordinator: coordinator)
      KeyTermsStepView()
    }
  }
}

/// The occasional stuff: checking for an update and the developer-mode log
/// toggle. Kept out of General so the common pane stays short.
private struct AdvancedSettingsTab: View {
  let updateModel: UpdateCheckModel

  var body: some View {
    SettingsPane {
      UpdateSection(model: updateModel)
      DeveloperSection()
    }
  }
}

/// The Updates section of the Settings window: the running version and a
/// "Check for Updates" button that runs the check and reports the result in a
/// modal (see `UpdateCheckModel`). The same check is reachable from the
/// "Check for Updates…" app-menu command and the menu-bar item; all three share
/// the one `UpdateCheckModel` owned by `AppDelegate`, so a check from any place
/// runs through the same controller.
private struct UpdateSection: View {
  let model: UpdateCheckModel

  var body: some View {
    Section {
      SettingRow(title: versionTitle, systemImage: "arrow.triangle.2.circlepath") {
        Button("Check for Updates") { model.checkForUpdates() }
          .accessibilityIdentifier(UITestIdentifiers.updateCheck)
      }
    } header: {
      Text("Updates")
    }
  }

  /// "Blurt 0.1.31" when the version is known, otherwise a plain "Blurt" (the
  /// button still works — the check reads the version itself).
  private var versionTitle: String {
    model.currentVersionText.map { "Blurt \($0)" } ?? "Blurt"
  }
}

/// The Developer section of the Settings window: an opt-in switch for developer
/// mode. While on, every completed dictation is appended to the local JSONL log
/// (see `DictationLog` — its gate reads the same default this toggle writes),
/// and the footer shows where that log lives so it's easy to find. Settings-only
/// — not a wizard step, since it never gates setup. (Housed here rather than in
/// its own file so the committed XcodeGen project doesn't need regenerating;
/// move it to its own file next time `xcodegen generate` runs anyway.)
private struct DeveloperSection: View {
  @AppStorage(DeveloperModeStore.defaultsKey) private var developerMode = false

  var body: some View {
    Section {
      Toggle(isOn: $developerMode) {
        Label("Developer mode", systemImage: "hammer")
      }
      .accessibilityIdentifier(UITestIdentifiers.developerToggle)
    } header: {
      Text("Developer")
    } footer: {
      Text("Logs each dictation to \(Self.logPath).")
        .textSelection(.enabled)
    }
  }

  /// The dictation log's location, home-abbreviated for display (the engine
  /// exposes the real URL so this label can never drift from where the log is
  /// actually written).
  private static var logPath: String {
    (DictationLog.defaultURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }
}
