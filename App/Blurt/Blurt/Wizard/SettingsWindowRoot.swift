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
