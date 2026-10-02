import AVFoundation
import BlurtDesign
import BlurtEngine
import BlurtiOSCore
import SwiftUI

/// The app's one screen: the Blurt landing page on a phone. The wordmark and
/// the gear across the top; the status as an eyebrow, a serif headline and a
/// line of body text over the voice element; the one green button; then the
/// styles and the recent dictations under their eyebrows. Setup sits on top
/// while anything is missing; everything adjustable lives behind the gear.
struct HomeView: View {
  var coordinator: DictationCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @State private var microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
  @State private var keyboardSeen = SharedStore.keyboardEverSeen
  @State private var showsKeyEntry = false
  @State private var showsSettings = false
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
      .sheet(isPresented: $showsSettings) { SettingsView(coordinator: coordinator) }
      .sheet(isPresented: Binding(get: { coordinator.needsConsent }, set: { coordinator.needsConsent = $0 })) {
        ConsentView { Task { await coordinator.grantConsent() } }
      }
      .sheet(item: Binding(get: { coordinator.pendingTermPack }, set: { coordinator.pendingTermPack = $0 })) {
        ImportTermsView(pack: $0)
      }
      .alert(
        "Couldn't read that list",
        isPresented: Binding(get: { coordinator.termPackUnreadable }, set: { coordinator.termPackUnreadable = $0 })
      ) {
        Button("OK") {}
      } message: {
        Text("It isn't a Blurt key-term list, or it's too big.")
      }
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
      Button {
        showsSettings = true
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: DesignTokens.Metrics.appIcon, weight: DesignTokens.Typography.weightGlyph))
          .foregroundStyle(BlurtBrand.muted)
      }
      .accessibilityLabel("Settings")
    }
    .frame(height: DesignTokens.Metrics.appHeaderHeight)
  }

  private func refreshStatus() {
    microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    keyboardSeen = SharedStore.keyboardEverSeen
    coordinator.apiKey.refreshStatus()
  }
}
