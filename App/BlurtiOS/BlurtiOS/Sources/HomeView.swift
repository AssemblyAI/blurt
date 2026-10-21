import AVFoundation
import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// The Dictate tab: the Blurt landing page on a phone. The wordmark and
/// the gear across the top; the lifetime stats; the session card (on or off,
/// its switch, a box to try the keyboard in); then the styles and the recent
/// dictations under their eyebrows. Setup comes before
/// the tabs (`SetupView`) and lives in Settings after; everything adjustable
/// is behind the gear.
struct HomeView: View {
  var coordinator: DictationCoordinator
  /// Opens Settings, which `MainView` presents over either tab.
  let showSettings: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @State private var microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
  @State private var keyboardSeen = SharedStore.keyboardEverSeen

  private var status: HomeStatus {
    HomeStatus(
      overlay: coordinator.overlay, windowOpen: coordinator.window.isOpen,
      windowMinutes: SharedStore.windowMinutes, micDenied: coordinator.microphoneDenied,
      hasKey: coordinator.apiKey.hasAPIKey, micGranted: microphoneGranted, keyboardSeen: keyboardSeen)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appSectionGap) {
          header
          StatsCard()
          HomeHero(coordinator: coordinator, status: status)
          StyleChips()
          RecentSection(coordinator: coordinator)
          Eyebrow("Powered by AssemblyAI")
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, DesignTokens.Metrics.appPagePad)
        .padding(.bottom, DesignTokens.Metrics.appSectionGap)
      }
      // "Try it here" brings a keyboard up on this page; a drag puts it away.
      .scrollDismissesKeyboard(.interactively)
      .page()
      .toolbar(.hidden, for: .navigationBar)
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { refreshStatus() }
      }
    }
    .tint(BlurtBrand.accent)
  }

  /// The wordmark, and the gear that opens Settings.
  private var header: some View {
    HStack {
      Wordmark()
      Spacer()
      SettingsButton(action: showSettings)
    }
    .frame(height: DesignTokens.Metrics.appHeaderHeight)
  }

  private func refreshStatus() {
    microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    keyboardSeen = SharedStore.keyboardEverSeen
    coordinator.apiKey.refreshStatus()
  }
}
