import AVFoundation
import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// The first-run setup screen until Blurt is set up, then the tabs
/// (`SetupProgress`). Whoever was already set up when this arrived goes
/// straight to the tabs: the check is taken once, at launch, so finishing the
/// last step on the setup screen doesn't yank it away mid-read.
struct RootView: View {
  var coordinator: DictationCoordinator
  @AppStorage(SetupProgress.finishedKey) private var finished = false
  @State private var wasSetUpAtLaunch =
    AVAudioApplication.shared.recordPermission == .granted && SharedStore.keyboardEverSeen

  var body: some View {
    if SetupProgress.needsSetup(
      hasKey: coordinator.apiKey.hasAPIKey, isSetUp: wasSetUpAtLaunch, finished: finished)
    {
      SetupView(coordinator: coordinator)
        .onOpenURL { coordinator.handle($0) }
    } else {
      MainView(coordinator: coordinator)
    }
  }
}

/// The app: the Dictate and Words tabs under the brand tab bar, plus what has
/// to work whichever tab is showing — Settings from either tab's gear, the
/// consent prompt the keyboard's `blurt://start` can raise, and a shared
/// key-term list arriving from Messages.
struct MainView: View {
  enum Tab: CaseIterable, Identifiable {
    case dictate, words

    var id: Self { self }

    var label: String {
      switch self {
      case .dictate: "Dictate"
      case .words: "Words"
      }
    }

    var symbol: String {
      switch self {
      case .dictate: "mic"
      case .words: "character.book.closed"
      }
    }
  }

  var coordinator: DictationCoordinator
  @State private var tab = Tab.dictate
  @State private var showsSettings = false

  var body: some View {
    Group {
      switch tab {
      case .dictate: HomeView(coordinator: coordinator) { showsSettings = true }
      case .words: WordsView(coordinator: coordinator) { showsSettings = true }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BrandTabBar(Tab.allCases, selection: $tab, label: \.label, symbol: \.symbol)
    }
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
    // The keyboard's `blurt://start` is about the listening window, which the
    // Dictate tab shows; a key-term list lands on Words, where it's added.
    .onOpenURL { url in
      tab = TermPack.looksLikePack(url) ? .words : .dictate
      coordinator.handle(url)
    }
    .tint(BlurtBrand.accent)
  }
}
