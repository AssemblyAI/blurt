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
      PickerSettingRow(
        title: "Dictation key", systemImage: "keyboard",
        accessibilityID: "settings.hotkey.picker", selection: $selection
      ) {
        ForEach(TriggerKey.allCases, id: \.self) { key in
          Text(key.label).tag(key)
        }
      }
      .onChange(of: selection) { _, newValue in
        TriggerKeyStore().triggerKey = newValue
        coordinator.dictationBindingChanged()
      }
    } header: {
      Text("Shortcut")
    } footer: {
      Text("Tap to start and tap again to stop, or hold the key and release to dictate.")
    }
  }
}

/// A settings-form row: an icon-and-title label on the left, a compact menu
/// picker on the right. Shared by the shortcut and sound sections so the two
/// rows stay visually identical. (Housed here rather than in its own file so
/// the committed XcodeGen project doesn't need regenerating; move it to its own
/// file next time `xcodegen generate` runs anyway.)
struct PickerSettingRow<Value: Hashable, Options: View>: View {
  var title: String
  var systemImage: String
  var accessibilityID: String
  @Binding var selection: Value
  @ViewBuilder var options: () -> Options

  var body: some View {
    LabeledContent {
      // The picker carries its real title (hidden from layout — the visible
      // label is the `LabeledContent` one) so VoiceOver reads a meaningful
      // name for the pop-up button rather than an empty string.
      Picker(title, selection: $selection, content: options)
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier(accessibilityID)
    } label: {
      Label(title, systemImage: systemImage)
    }
  }
}
