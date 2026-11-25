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
  /// A secondary line under the title — a preview of what the row holds (a
  /// style's instructions). Truncates rather than wraps, so every row keeps
  /// one height.
  var subtitle: String?
  @ViewBuilder var trailing: () -> Trailing

  var body: some View {
    HStack {
      SettingLabel(title: title, systemImage: systemImage, subtitle: subtitle)
        // The row label is two or three words and names the setting, so it never
        // wraps: when the trailing control is wide (the mic picker's "Same as
        // system (MacBook Pro Microphone)"), the control truncates and the label
        // stays whole. Without this the label was the compressible view and
        // "Input device" broke across two lines, which also made that one row
        // taller than every other row in the form. A row with a subtitle stays
        // compressible instead: the preview is the part that should give way.
        .lineLimit(1)
        .fixedSize(horizontal: subtitle == nil, vertical: false)
      Spacer(minLength: 12)
      trailing()
    }
  }
}
