import AVFoundation
import BlurtDesign
import BlurtiOSCore
import SwiftUI

/// The first-run setup screen until Blurt is set up, then the tabs
/// (`SetupProgress`). Whoever was already set up when this arrived goes
/// straight to the tabs: the check is taken once, at launch, so finishing the
/// last step on the setup screen doesn't yank it away mid-read.
///
/// Over either, Blurt is on (`KeepOpenView`) whenever the scene leaves the
/// front with a listening window on: a layer that fades in, never a
/// presentation, so what iOS shows as Blurt's card in the app switcher, and
/// keeps as its snapshot, says to keep Blurt in the background. It fades out
/// again as the app comes back to the front.
struct RootView: View {
  var coordinator: DictationCoordinator
  @AppStorage(SetupProgress.finishedKey) private var finished = false
  @Environment(\.scenePhase) private var scenePhase
  @State private var wasSetUpAtLaunch =
    AVAudioApplication.shared.recordPermission == .granted && SharedStore.keyboardEverSeen

  /// Away from the front with a window on. `isOn` reads the machine, which
  /// observation doesn't track; the record it publishes is, so reading that
  /// too means a window closing on its own while the card is up — its time
  /// run out, a call — takes the card down with it.
  private var showsKeepOpen: Bool {
    _ = coordinator.window.state
    return scenePhase != .active && coordinator.window.isOn
  }

  var body: some View {
    ZStack {
      if SetupProgress.needsSetup(
        hasKey: coordinator.apiKey.hasAPIKey, isSetUp: wasSetUpAtLaunch, finished: finished)
      {
        SetupView(coordinator: coordinator)
          .onOpenURL { coordinator.handle($0) }
      } else {
        MainView(coordinator: coordinator)
      }
      if showsKeepOpen {
        KeepOpenView(windowMinutes: SharedStore.windowMinutes)
          .transition(.opacity)
          .zIndex(1)
      }
    }
    .animation(
      .timingCurve(DesignTokens.Motion.easeSignature, duration: DesignTokens.Motion.keepOpenFade),
      value: showsKeepOpen
    )
    // The Picture in Picture keeper's source layer, when that is the idle
    // mode: Picture in Picture is only possible for a layer on screen, so it
    // sits in the hierarchy whichever screen is up — a point tall, nothing to
    // see, nothing for VoiceOver — and the window can start under either.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let keeper = coordinator.window.pictureInPictureKeeper {
        PictureInPictureSource(keeper: keeper)
          .frame(width: PictureInPictureKeeper.sourceSize.width, height: 1)
          .accessibilityHidden(true)
      }
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
  @Environment(\.scenePhase) private var scenePhase
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
    // A session by default: opening Blurt turns one on (when nothing needs
    // asking first, and the user hasn't turned it off), so the keyboard is
    // ready without a trip to the switch — and a window paused by a call
    // starts its microphone again, now that the app is in front.
    .task { await coordinator.startSessionIfReady() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await coordinator.startSessionIfReady() } }
      // Back in the app the user was typing in: the ◀ hint and the Full
      // Access note have done their job. Here rather than on the Dictate
      // tab, which isn't there while Words is.
      if phase == .background { coordinator.sceneLeft() }
    }
    .tint(BlurtBrand.accent)
  }
}
