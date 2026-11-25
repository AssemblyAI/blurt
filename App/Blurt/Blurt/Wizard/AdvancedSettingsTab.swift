import SwiftUI

/// The occasional stuff: checking for an update, the developer-mode log
/// toggle, and the
/// start-over button. Kept out of General so
/// the common pane stays short.
struct AdvancedSettingsTab: View {
  let coordinator: AppCoordinator
  let updaterModel: UpdaterModel

  var body: some View {
    SettingsPane {
      UpdatesSection(model: updaterModel)
      MaintenanceSection()
      ExperimentalSection()
      ResetSection(coordinator: coordinator)
    }
  }
}
