import SwiftUI

/// A settings/setup-form row: an icon-and-title label on the leading edge, with
/// trailing content pushed to the trailing edge and vertically centered against
/// the label. A plain `HStack` (default `.center` alignment) rather than
/// `LabeledContent`, which baseline-aligns the control to the label and leaves
/// it reading slightly high. Shared so every settings/setup row stays visually
/// identical (see `APIKeyStepView`, `PermissionsStepView`, `PickerSettingRow`).
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
