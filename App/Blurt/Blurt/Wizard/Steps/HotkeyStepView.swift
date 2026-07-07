import BlurtEngine
import SwiftUI

/// The dictation-key section of the setup/settings screen. A menu picker lets
/// the user choose which lone modifier triggers dictation; changes are persisted
/// and pushed to the event tap immediately.
struct HotkeyStepView: View {
  var coordinator: AppCoordinator

  @AppStorage(TriggerKeyStore.defaultsKey) private var triggerKeyCode = TriggerKey.rightCommand.rawValue

  private var selection: Binding<TriggerKey> {
    Binding(
      get: {
        TriggerKey.fromPersisted(triggerKeyCode)
      },
      set: { newValue in
        triggerKeyCode = newValue.rawValue
        coordinator.dictationBindingChanged()
      })
  }

  var body: some View {
    Section {
      PickerSettingRow(
        title: "Dictation key", systemImage: "keyboard",
        accessibilityID: UITestIdentifiers.hotkeyPicker, selection: selection
      ) {
        ForEach(TriggerKey.allCases, id: \.self) { key in
          Text(key.label).tag(key)
        }
      }
    } header: {
      Text("Shortcut")
    } footer: {
      Text("Tap to start and tap again to stop, or hold the key and release to dictate.")
    }
  }
}

/// A settings/setup-form row: an icon-and-title label on the leading edge, with
/// trailing content pushed to the trailing edge and vertically centered against
/// the label. A plain `HStack` (default `.center` alignment) rather than
/// `LabeledContent`, which baseline-aligns the control to the label and leaves
/// it reading slightly high. Shared so every settings/setup row stays visually
/// identical (see `APIKeyStepView.savedRow`, `PermissionsStepView`,
/// `PickerSettingRow`). (Housed here rather than in its own file so the
/// committed XcodeGen project doesn't need regenerating; move it to its own file
/// next time `xcodegen generate` runs anyway.)
struct SettingRow<Trailing: View>: View {
  var title: String
  var systemImage: String
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack {
      Label(title, systemImage: systemImage)
      Spacer(minLength: 12)
      trailing()
    }
  }
}

/// A `SettingRow` whose trailing content is a compact menu picker. Shared by the
/// shortcut and sound sections so the two rows stay identical.
struct PickerSettingRow<Value: Hashable, Options: View>: View {
  var title: String
  var systemImage: String
  var accessibilityID: String
  @Binding var selection: Value
  @ViewBuilder var options: () -> Options

  var body: some View {
    SettingRow(title: title, systemImage: systemImage) {
      // The picker keeps its own (hidden) title so VoiceOver reads a meaningful
      // name for the pop-up button rather than an empty string.
      Picker(title, selection: $selection, content: options)
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityIdentifier(accessibilityID)
    }
  }
}
