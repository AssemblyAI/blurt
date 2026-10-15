import AVFoundation
import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// The first-run screen, in place of the tabs until Blurt is set up, as in the
/// blurt-ios prototype: the wordmark, a headline, and the three steps in a
/// card. The key comes first and can't be skipped, since nothing works without
/// it; once it is in, the user can start right away and finish the microphone
/// and the keyboard later from Settings, where the steps move.
struct SetupView: View {
  var coordinator: DictationCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(SetupProgress.finishedKey) private var finished = false
  @State private var microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
  @State private var keyboardSeen = SharedStore.keyboardEverSeen

  private var hasKey: Bool { coordinator.apiKey.hasAPIKey }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignTokens.Metrics.appSectionGap) {
        Wordmark()
          .frame(height: DesignTokens.Metrics.appHeaderHeight)
        Text(
          hasKey ? "Two more steps and you can dictate anywhere." : "Paste an AssemblyAI API key to start dictating."
        )
        .font(BlurtType.heading(DesignTokens.Typography.sizeTitle))
        .foregroundStyle(BlurtBrand.text)
        .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
          Eyebrow("Set up Blurt")
          SetupSteps(
            hasKey: hasKey, microphoneGranted: microphoneGranted, keyboardSeen: keyboardSeen, refresh: refresh
          ) {
            KeyStep(apiKey: coordinator.apiKey)
          }
        }
        .padding(DesignTokens.Metrics.appCardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        if hasKey {
          Button("Start dictating") { finished = true }
            .buttonStyle(BrandButtonStyle())
          Text("You can finish these later in Settings.")
            .brandFootnote()
        }
      }
      .padding(.horizontal, DesignTokens.Metrics.appPagePad)
      .padding(.bottom, DesignTokens.Metrics.appSectionGap)
    }
    .scrollDismissesKeyboard(.interactively)
    .page()
    .tint(BlurtBrand.accent)
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { refresh() }
    }
  }

  private func refresh() {
    microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    keyboardSeen = SharedStore.keyboardEverSeen
    coordinator.apiKey.refreshStatus()
  }
}

/// Paste a key, checked with AssemblyAI before it is saved (`APIKeySubmission`
/// owns that rule), as on the prototype's first screen: the field, Continue,
/// Get a free key, and what happens to the key and the audio.
private struct KeyStep: View {
  var apiKey: APIKeyModel
  @Environment(\.openURL) private var openURL
  @State private var draft = ""
  @State private var isChecking = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Metrics.appStackGap) {
      SecureField("Paste your API key", text: $draft)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .onSubmit { Task { await submit() } }
        .brandInput()
      if let errorMessage {
        Text(errorMessage)
          .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
          .foregroundStyle(BlurtBrand.errorOrange)
          .fixedSize(horizontal: false, vertical: true)
      }
      // Stacked, not side by side: at half the card's width the mono labels
      // wrap ("GET A / FREE KEY").
      VStack(spacing: DesignTokens.Metrics.appChipGap) {
        Button(isChecking ? "Checking…" : "Continue") { Task { await submit() } }
          .buttonStyle(BrandButtonStyle())
          .disabled(isChecking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Get a free key") { openURL(APIKeyStore.dashboardURL) }
          .buttonStyle(BrandButtonStyle(role: .secondary))
      }
      Text(
        "Blurt sends what you dictate to AssemblyAI to transcribe it, using this key. "
          + "New accounts come with free credits. The key is stored in this iPhone's Keychain."
      )
      .brandFootnote()
    }
  }

  private func submit() async {
    guard !isChecking else { return }
    isChecking = true
    defer { isChecking = false }
    switch await apiKey.submit(draft).failureReport {
    case .none:
      errorMessage = nil
      draft = ""
    case .some(.inline(let message)): errorMessage = message
    case .some(.alert(let title, let message)): errorMessage = "\(title) \(message)"
    }
  }
}
