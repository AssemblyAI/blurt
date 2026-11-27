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
  @AppStorage(SetupProgress.finishedKey)
  private var finished = false
  @Environment(\.scenePhase)
  private var scenePhase
  @State private var wasSetUpAtLaunch: Bool

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
        hasKey: coordinator.apiKey.hasAPIKey, isSetUp: wasSetUpAtLaunch, finished: finished
      ) {
        SetupView(coordinator: coordinator)
          .onOpenURL { coordinator.handle($0) }
      } else {
        MainView(coordinator: coordinator)
      }
      if showsKeepOpen {
        KeepOpenView(windowMinutes: coordinator.store.windowMinutes)
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

  init(coordinator: DictationCoordinator) {
    self.coordinator = coordinator
    _wasSetUpAtLaunch = State(
      initialValue: AVAudioApplication.shared.recordPermission == .granted && coordinator.store.keyboardEverSeen
    )
  }
}
