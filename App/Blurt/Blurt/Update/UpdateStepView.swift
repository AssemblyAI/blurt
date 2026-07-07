import SwiftUI

/// The Settings "Updates" section: the running version and a "Check for Updates"
/// button that runs the check and reports the result in a modal (see
/// `UpdateCheckModel`). The same check is also available from the
/// "Check for Updates…" app-menu command; both share one `UpdateCheckModel`.
struct UpdateStepView: View {
  /// Shared with the menu command (owned by `AppDelegate`), so a check triggered
  /// from either place runs through the same controller.
  let model: UpdateCheckModel

  var body: some View {
    Section {
      // Plain HStack (default `.center` vertical alignment) so the button sits
      // centered against the version text — matches the other settings rows.
      HStack {
        if let version = model.currentVersionText {
          Text("Blurt \(version)")
        }
        Spacer(minLength: 12)
        Button("Check for Updates") { model.checkForUpdates() }
          .accessibilityIdentifier(UITestIdentifiers.updateCheck)
      }
    } header: {
      Text("Updates")
    }
  }
}
