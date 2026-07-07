import BlurtEngine
import SwiftUI

/// Root view of the `Settings` scene: change the AssemblyAI API key or the
/// dictation shortcut. Reuses the same section views the wizard's setup step
/// uses, so the two stay in sync.
struct SettingsWindowRoot: View {
  var appDelegate: AppDelegate

  var body: some View {
    if let coordinator = appDelegate.coordinator {
      Form {
        APIKeyStepView(coordinator: coordinator)
        HotkeyStepView(coordinator: coordinator)
        SoundStepView(coordinator: coordinator)
        KeyTermsStepView()
        DeveloperSection()
      }
      .formStyle(.grouped)
      .scrollDisabled(true)
      .frame(width: 480)
      .fixedSize(horizontal: false, vertical: true)
    } else {
      Color.clear.frame(width: 480, height: 240)
    }
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
      Text("Logs each dictation (raw and polished text, prompt, app context) to \(Self.logPath).")
        .textSelection(.enabled)
    }
  }

  /// The dictation log's location, home-abbreviated for display (the engine
  /// exposes the real URL so this label can never drift from where the log is
  /// actually written).
  private static var logPath: String {
    let path = DictationLog.defaultURL.path(percentEncoded: false)
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}
