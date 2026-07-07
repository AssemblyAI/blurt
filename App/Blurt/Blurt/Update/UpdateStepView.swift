import SwiftUI

/// The Settings "Updates" section. Idle it shows **Check for Update**; while a
/// check runs it shows a spinner; a result either reports "You're on the latest
/// version" inline or swaps the button to **Download Blurt X.Y.Z**, which opens
/// the release DMG in the browser. Replaces the old launch-time self-updater.
struct UpdateStepView: View {
  @State private var model = UpdateCheckModel()

  var body: some View {
    Section {
      switch model.state {
      case .available(let version, _):
        Button("Download Blurt \(version)") { model.download() }
      case .checking:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Checking for updates…").foregroundStyle(.secondary)
        }
      default:
        Button("Check for Update") {
          Task { await model.check() }
        }
      }
    } header: {
      Text("Updates")
    } footer: {
      footer
    }
  }

  /// Inline result text — only for the two terminal informational states; the
  /// button itself carries idle/checking/available.
  @ViewBuilder private var footer: some View {
    switch model.state {
    case .upToDate(let version):
      Text("You're on the latest version (\(version)).")
    case .failed:
      Text("Couldn't check for updates. Check your connection and try again.")
    default:
      EmptyView()
    }
  }
}
