import BlurtEngine
import SwiftUI

/// The dictation-key section of the setup/settings screen. A menu picker lets
/// the user choose which lone modifier triggers dictation; changes are persisted
/// and pushed to the event tap immediately.
struct HotkeyStepView: View {
  var coordinator: AppCoordinator

  @State private var selection: TriggerKey = TriggerKeyStore().triggerKey

  var body: some View {
    Section {
      LabeledContent {
        Picker("", selection: $selection) {
          ForEach(TriggerKey.allCases, id: \.self) { key in
            Text(key.label).tag(key)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier("settings.hotkey.picker")
        .onChange(of: selection) { _, newValue in
          TriggerKeyStore().triggerKey = newValue
          coordinator.dictationBindingChanged()
        }
      } label: {
        Label("Dictation key", systemImage: "keyboard")
      }
    } header: {
      Text("Shortcut")
    } footer: {
      Text("Tap to start and tap again to stop, or hold the key and release to dictate.")
    }
  }
}
