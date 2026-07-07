import SwiftUI

/// The Settings "Updates" section — one stable row modeled on macOS Software
/// Update: a status label leads, the action button trails. The button is never
/// removed (a spinner appears beside it while checking), so the row — and the
/// window that fixed-sizes to it — keeps a constant height across states rather
/// than collapsing mid-check. The check result reads inline in the row ("Blurt X
/// is up to date" / "Blurt X is available" / a recoverable error), not in a
/// footer. When an update exists the button becomes a prominent "Download Blurt
/// X.Y.Z" that opens the release DMG in the browser. Replaces the old
/// launch-time self-updater.
struct UpdateStepView: View {
  @State private var model = UpdateCheckModel()

  var body: some View {
    Section {
      LabeledContent {
        HStack(spacing: 8) {
          if model.state.isChecking {
            ProgressView().controlSize(.small)
          }
          actionButton
        }
      } label: {
        statusLabel
      }
    } header: {
      Text("Updates")
    }
  }

  /// Trailing control: "Download Blurt X.Y.Z" (prominent) when an update is
  /// available, otherwise "Check for Updates" — disabled while a check runs so
  /// the row stays put and the check can't be re-fired mid-flight.
  @ViewBuilder private var actionButton: some View {
    switch model.state {
    case .available(let version, _):
      Button("Download Blurt \(version)") { model.download() }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier(UITestIdentifiers.updateDownload)
    default:
      Button("Check for Updates") {
        Task { await model.check() }
      }
      .disabled(model.state.isChecking)
      .accessibilityIdentifier(UITestIdentifiers.updateCheck)
    }
  }

  /// Leading status text — the resting installed version, the in-flight note,
  /// or the check outcome. A recoverable failure reads in red (no caution glyph,
  /// which would signal a critical/destructive state rather than "try again").
  @ViewBuilder private var statusLabel: some View {
    switch model.state {
    case .idle:
      if let current = model.currentVersionText {
        Text("Blurt \(current)")
      }
    case .checking:
      Text("Checking for updates…").foregroundStyle(.secondary)
    case .upToDate(let version):
      Text("Blurt \(version) is up to date")
    case .available(let version, _):
      Text("Blurt \(version) is available")
    case .failed:
      Text("Couldn't check for updates. Check your connection and try again.")
        .foregroundStyle(.red)
    }
  }
}
