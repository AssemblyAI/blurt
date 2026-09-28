import SwiftUI

/// The Updates section for the running version and user-initiated checks.
struct UpdateSection: View {
  @ObservedObject var model: UpdateCheckModel

  var body: some View {
    Section {
      SettingRow(title: model.versionLabel, systemImage: "arrow.triangle.2.circlepath") {
        HStack(spacing: 8) {
          if model.isChecking { ProgressView().controlSize(.small) }
          Button("Check for Updates") { model.checkForUpdates() }
            .disabled(model.isChecking)
            .accessibilityIdentifier(UITestIdentifiers.updateCheck)
        }
      }
    } header: {
      Text("Updates")
    }
  }
}
