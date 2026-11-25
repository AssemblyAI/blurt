import SwiftUI

/// A `SettingRow` whose trailing content is a compact menu picker. Shared by the
/// shortcut and sound sections so the two rows stay identical.
struct PickerSettingRow<Value: Hashable, Options: View>: View {
  var title: String
  var systemImage: String
  var accessibilityID: String
  var subtitle: String?
  /// What VoiceOver calls the pop-up, when the row's title alone doesn't say
  /// what it sets (a Sounds row is titled with its key). Defaults to the title.
  var pickerLabel: String?
  @Binding var selection: Value
  @ViewBuilder var options: () -> Options

  var body: some View {
    SettingRow(title: title, systemImage: systemImage, subtitle: subtitle) {
      // The picker keeps its own (hidden) title so VoiceOver reads a meaningful
      // name for the pop-up button rather than an empty string.
      Picker(pickerLabel ?? title, selection: $selection, content: options)
        .labelsHidden()
        .pickerStyle(.menu)
        // Deliberately *not* `.fixedSize()`: the pop-up hugs its title anyway
        // (the row's `Spacer` absorbs the slack), but staying compressible
        // means a title too long for the row — the mic picker's "Same as
        // system (MacBook Pro Microphone)" — truncates inside the control
        // instead of forcing the leading label to wrap.
        .lineLimit(1)
        .accessibilityIdentifier(accessibilityID)
    }
  }
}
