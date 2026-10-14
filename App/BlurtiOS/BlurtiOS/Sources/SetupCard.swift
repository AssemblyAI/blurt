import AVFoundation
import BlurtEngine
import SwiftUI
import UIKit

/// The setup checklist, on top of the home screen while anything is missing:
/// three numbered steps — an AssemblyAI API key, the microphone, the keyboard —
/// each with its control until it is done.
struct SetupCard: View {
  let hasKey: Bool
  let microphoneGranted: Bool
  let keyboardSeen: Bool
  /// Every build takes an API key, as the Mac app does, until Sign in with
  /// AssemblyAI exists.
  let enterKey: () -> Void
  /// Re-read the permissions after one was asked for.
  let refresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
      Eyebrow("Set up Blurt")
      SetupRow(number: "01", done: hasKey, title: "Add your AssemblyAI API key") {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
          Text("Blurt uses your own AssemblyAI account. New accounts come with free credits.")
            .font(BlurtType.body(DesignTokens.Typography.sizeCaption)).foregroundStyle(BlurtBrand.muted)
          Button("Paste your key") { enterKey() }.buttonStyle(BrandButtonStyle(role: .primary))
          Link("Get a free key", destination: APIKeyStore.dashboardURL)
            .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
        }
      }
      SetupRow(number: "02", done: microphoneGranted, title: "Allow the microphone") {
        if AVAudioApplication.shared.recordPermission == .denied {
          // iOS asks once; after a refusal only Settings can change it.
          Button("Allow in Settings") { Self.openAppSettings() }.buttonStyle(BrandButtonStyle(role: .primary))
        } else {
          Button("Allow") {
            Task {
              _ = await AVAudioApplication.requestRecordPermission()
              refresh()
            }
          }
          .buttonStyle(BrandButtonStyle(role: .primary))
        }
      }
      SetupRow(number: "03", done: keyboardSeen, title: "Add the Blurt keyboard") {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
          // The button's link (`openSettingsURLString`) is the only Settings
          // link Apple allows — the General › Keyboard deep links are private
          // API and fail review. It is meant to land on Blurt's own page, where
          // iOS puts a Keyboards row for any app with a keyboard, but not every
          // build honours it (the iOS 26 simulator opens Settings' top level),
          // so the steps name the whole path, which holds from either screen.
          Text(
            "In Settings, go to Apps › Blurt › Keyboards, turn on Blurt, then Allow Full Access. "
              + "Full Access is what lets the keyboard send your words to Blurt."
          )
          .font(BlurtType.body(DesignTokens.Typography.sizeCaption)).foregroundStyle(BlurtBrand.muted)
          Button("Open Settings") { Self.openAppSettings() }.buttonStyle(BrandButtonStyle(role: .secondary))
        }
      }
    }
    .padding(DesignTokens.Metrics.appCardPad)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  static func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}

/// One step: its number in mono, the step, and its control while it is still
/// to do; a check when done.
private struct SetupRow<Action: View>: View {
  let number: String
  let done: Bool
  let title: String
  @ViewBuilder let action: () -> Action

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Metrics.appStackGap) {
      Eyebrow(number, color: done ? BlurtBrand.accent : BlurtBrand.muted)
        .frame(width: DesignTokens.Metrics.appSetupNumberWidth, alignment: .leading)
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appLineGap) {
        HStack {
          Text(title).font(BlurtType.body(DesignTokens.Typography.sizeBody)).foregroundStyle(BlurtBrand.text)
          if done { Image(systemName: "checkmark").foregroundStyle(BlurtBrand.accent) }
        }
        if !done { action() }
      }
    }
  }
}
