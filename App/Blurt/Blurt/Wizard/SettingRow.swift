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
      // The glyph carries the brand green, the title stays label-colored: the
      // design tints only the icon, and a green title would read as a link.
      // Built with the closure form and the color applied to the `Image` alone,
      // rather than `.foregroundStyle(.primary, BlurtBrand.accent)` on a
      // `Label(_:systemImage:)` — a label's icon doesn't reliably draw at the
      // secondary style level, so the two-argument form leaves it label-colored.
      Label {
        Text(title)
      } icon: {
        Image(systemName: systemImage)
          .foregroundStyle(BlurtBrand.accent)
      }
      // The row label is two or three words and names the setting, so it never
      // wraps: when the trailing control is wide (the mic picker's "Same as
      // system (MacBook Pro Microphone)"), the control truncates and the label
      // stays whole. Without this the label was the compressible view and
      // "Input device" broke across two lines, which also made that one row
      // taller than every other row in the form.
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
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
