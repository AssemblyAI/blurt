import AVFoundation
import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// The first-run screen, in place of the tabs until Blurt is set up: the
/// wordmark, a headline, and the three steps in a
/// card. The key comes first and can't be skipped, since nothing works without
/// it; once it is in, the user can start right away and finish the microphone
/// and the keyboard later from Settings, where the steps move.
struct SetupView: View {
  var coordinator: DictationCoordinator
  @Environment(\.scenePhase)
  private var scenePhase
  @AppStorage(SetupProgress.finishedKey)
  private var finished = false
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
        // The keyboard sent the user here for Full Access (`blurt://setup`):
        // step 03 below is the one to finish, and no session starts until then.
        if coordinator.needsFullAccess {
          Text("The Blurt keyboard needs Full Access to dictate: finish step 03.")
            .font(BlurtType.body(DesignTokens.Typography.sizeCaption))
            .foregroundStyle(BlurtBrand.errorOrange)
            .fixedSize(horizontal: false, vertical: true)
        }
        stepsCard
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

  /// The three steps, in a card under their eyebrow.
  private var stepsCard: some View {
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
  }

  private func refresh() {
    microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    keyboardSeen = SharedStore.keyboardEverSeen
    coordinator.apiKey.refreshStatus()
  }
}
