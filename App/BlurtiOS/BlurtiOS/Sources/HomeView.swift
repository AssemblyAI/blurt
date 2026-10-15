import AVFoundation
import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// The Dictate tab: the Blurt landing page on a phone. The wordmark and
/// the gear across the top; the status as an eyebrow, a serif headline and a
/// line of body text over the voice element; the one green button; then the
/// styles and the recent dictations under their eyebrows. Setup sits on top
/// while anything is missing; everything adjustable lives behind the gear.
struct HomeView: View {
  var coordinator: DictationCoordinator
  /// Opens Settings, which `MainView` presents over either tab.
  let showSettings: () -> Void
  @Environment(\.scenePhase) private var scenePhase
  @State private var microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
  @State private var keyboardSeen = SharedStore.keyboardEverSeen
  @State private var showsKeyEntry = false
  /// When the last dictation's words landed — the hero's glint.
  @State private var landedAt: Date?
  /// TEMPORARY: the mic concept from Settings, so the hero shows the one
  /// the keyboard will. Goes with the losers.
  @AppStorage(BlurtShared.Key.voiceElement, store: SharedStore.defaults) private var voiceRaw =
    VoiceElementKind.shipped.rawValue

  private var status: HomeStatus {
    HomeStatus(
      overlay: coordinator.phase.overlayState, windowOpen: coordinator.window.isOpen, until: coordinator.window.until,
      hasKey: coordinator.apiKey.hasAPIKey, micGranted: microphoneGranted, keyboardSeen: keyboardSeen)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Metrics.appSectionGap) {
          header
          if !status.isSetUp {
            SetupCard(
              hasKey: coordinator.apiKey.hasAPIKey, microphoneGranted: microphoneGranted, keyboardSeen: keyboardSeen,
              enterKey: { showsKeyEntry = true }, refresh: refreshStatus)
          }
          HomeHero(coordinator: coordinator, status: status, landedAt: landedAt)
          StyleChips()
          RecentSection(coordinator: coordinator)
          Eyebrow("Powered by AssemblyAI")
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, DesignTokens.Metrics.appPagePad)
        .padding(.bottom, DesignTokens.Metrics.appSectionGap)
      }
      .page()
      .environment(\.voiceElementKind, VoiceElementKind(rawValue: voiceRaw) ?? .shipped)
      .toolbar(.hidden, for: .navigationBar)
      .sheet(isPresented: $showsKeyEntry) { KeyEntryView(apiKey: coordinator.apiKey) }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { refreshStatus() }
      }
      .onChange(of: coordinator.phase) { _, _ in
        if status.landed { landedAt = Date() }
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
