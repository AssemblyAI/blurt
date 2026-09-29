import AVFoundation
import BlurtEngine
import SwiftUI

/// The app's one screen, in the shape of the Mac's ready screen: the wordmark,
/// the orb as the hero with the listening state under it, the style chips,
/// and the recent dictations as cards. Setup sits on top while anything is
/// missing; everything adjustable lives behind the gear.
struct HomeView: View {
  var coordinator: DictationCoordinator
  @Environment(\.scenePhase) private var scenePhase
  @State private var microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
  @State private var keyboardSeen = SharedStore.keyboardEverSeen
  @State private var showsKeyEntry = false
  @State private var showsSettings = false
  /// When the last dictation's words landed — the hero's drop.
  @State private var landedAt: Date?

  private var status: HomeStatus {
    HomeStatus(
      overlay: coordinator.phase.overlayState, windowOpen: coordinator.window.isOpen, until: coordinator.window.until,
      hasKey: coordinator.apiKey.hasAPIKey, micGranted: microphoneGranted, keyboardSeen: keyboardSeen)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 20) {
          if !status.isSetUp {
            SetupCard(
              hasKey: coordinator.apiKey.hasAPIKey, microphoneGranted: microphoneGranted, keyboardSeen: keyboardSeen,
              enterKey: { showsKeyEntry = true }, refresh: refreshStatus)
          }
          HomeHero(coordinator: coordinator, status: status, landedAt: landedAt)
          StyleChips()
          RecentSection(coordinator: coordinator)
          poweredBy
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 24)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) { Wordmark() }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showsSettings = true
          } label: {
            Image(systemName: "gearshape")
          }
          .accessibilityLabel("Settings")
        }
      }
      .sheet(isPresented: $showsKeyEntry) { KeyEntryView(apiKey: coordinator.apiKey) }
      .sheet(isPresented: $showsSettings) { SettingsView(coordinator: coordinator) }
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

  private func refreshStatus() {
    microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    keyboardSeen = SharedStore.keyboardEverSeen
    coordinator.apiKey.refreshStatus()
  }

  private var poweredBy: some View {
    HStack(spacing: 3) {
      Text("Powered by").foregroundStyle(.secondary)
      Text("AssemblyAI").fontWeight(.medium)
    }
    .font(.caption)
    .padding(.top, 4)
  }
}
