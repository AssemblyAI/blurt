import AVFoundation
import SwiftUI
import UIKit

/// The setup checklist, on top of the home screen while anything is missing:
/// sign in (a key, in debug builds), the microphone, the keyboard.
struct SetupCard: View {
  let hasKey: Bool
  let microphoneGranted: Bool
  let keyboardSeen: Bool
  /// Debug builds take an API key in place of the sign-in that doesn't exist yet.
  let enterKey: () -> Void
  /// Re-read the permissions after one was asked for.
  let refresh: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Set up Blurt").font(.headline)
      SetupRow(done: hasKey, title: "Sign in with AssemblyAI") {
        VStack(alignment: .leading, spacing: 6) {
          Text("Coming soon — sign-in needs the AssemblyAI login service.")
            .font(.footnote).foregroundStyle(.secondary)
          #if DEBUG
            Button("Use an API key instead") { enterKey() }
          #endif
        }
      }
      SetupRow(done: microphoneGranted, title: "Allow the microphone") {
        if AVAudioApplication.shared.recordPermission == .denied {
          // iOS asks once; after a refusal only Settings can change it.
          Button("Allow in Settings") { Self.openAppSettings() }
        } else {
          Button("Allow") {
            Task {
              _ = await AVAudioApplication.requestRecordPermission()
              refresh()
            }
          }
        }
      }
      SetupRow(done: keyboardSeen, title: "Add the Blurt keyboard") {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "Settings → Keyboards: turn on Blurt and Allow Full Access. "
              + "Full Access is what lets the keyboard send your words to Blurt."
          )
          .font(.footnote).foregroundStyle(.secondary)
          Button("Open Settings") { Self.openAppSettings() }
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  static func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}

/// One line of the setup checklist: a check or a circle, the step, and its
/// control while it is still to do.
private struct SetupRow<Action: View>: View {
  let done: Bool
  let title: String
  @ViewBuilder let action: () -> Action

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: done ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(done ? BlurtBrand.accent : Color.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
        if !done { action() }
      }
    }
  }
}
