import BlurtEngine
import BlurtiOSCore
import SwiftUI

@main
struct BlurtiOSApp: App {
  @State private var coordinator: DictationCoordinator

  /// The composition root, and the first thing that runs: the engine's identity
  /// has to be set before any engine type is touched (`HostIdentity.configure`
  /// documents why), and the coordinator below touches the Keychain in its
  /// initializer. The identity is the iPhone app's own — its Keychain item is
  /// separate from the Mac app's by construction, since Keychains are per
  /// device, but naming it separately keeps the two builds' data apart the day
  /// they share an iCloud Keychain. The defaults prefix stays `Blurt` so the
  /// engine's stores read and write the same keys they do on the Mac. The log
  /// subsystem is the contract's (`BlurtShared.logSubsystem`): the keyboard
  /// logs under the same string, so one predicate reads both processes.
  init() {
    HostIdentity.configure(
      HostIdentity(
        productName: "Blurt",
        subsystem: BlurtShared.logSubsystem,
        keychainService: "blurt-ios",
        defaultsPrefix: "Blurt",
        logDirectoryName: "Blurt",
        // Styles live in a scrolling list here, not the Mac's five-button
        // switcher, so the phone allows far more than its four.
        styleProfileLimit: 100))
    #if DEBUG
      // `BLURT_DEBUG_API_KEY` (through simctl as `SIMCTL_CHILD_BLURT_DEBUG_API_KEY`)
      // puts a key in a simulator's Keychain without typing it, so a fresh
      // simulator can open the listening window from a script; debug builds only.
      if let key = ProcessInfo.processInfo.environment["BLURT_DEBUG_API_KEY"], !key.isEmpty, !Self.isTestHost {
        _ = APIKeyStore.save(key)
      }
      // The developer log and the device trace survive the hop's relaunch.
      if !Self.isTestHost { LaunchFlags.persist() }
    #endif
    // The unit tests are hosted by this app: they get a coordinator that
    // touches neither the Keychain nor the App Group (the Mac's UITestSupport
    // does the same for its harness), and `start()` below never runs.
    let coordinator =
      Self.isTestHost || Self.isKeyless
      ? DictationCoordinator(apiKey: APIKeyModel(keyStore: InMemoryAPIKeyStore())) : DictationCoordinator()
    _coordinator = State(initialValue: coordinator)
  }

  private static var isTestHost: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  /// `-BlurtNoKey`: a fresh install's view of the key, in memory, so the
  /// first-run screen can be screenshotted without touching the Keychain's;
  /// debug builds only.
  private static var isKeyless: Bool {
    #if DEBUG
      CommandLine.arguments.contains("-BlurtNoKey")
    #else
      false
    #endif
  }

  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if let probe = KeyboardProbeView.parse(CommandLine.arguments) {
          // The keyboard over this field is only live if the app runs as it
          // does under the home screen: the coordinator up, listening on request.
          probe.task { await start() }
        } else if CommandLine.arguments.contains("-BlurtTypingTest") {
          // The easter egg as the root, for a screenshot without a tap.
          TypingTestView()
        } else if CommandLine.arguments.contains("-BlurtSettings") {
          // The settings sheet as the root, for a screenshot without a tap.
          SettingsView(coordinator: coordinator)
        } else if CommandLine.arguments.contains("-BlurtKeepOpen") {
          // The app-switcher card as the root, for a screenshot or a recording
          // without a trip to the switcher; `-BlurtGalleryStill` holds it at
          // time zero.
          KeepOpenView(
            windowMinutes: SharedStore.windowMinutes, still: CommandLine.arguments.contains("-BlurtGalleryStill"))
        } else {
          home
        }
      #else
        home
      #endif
    }
  }

  private var home: some View {
    RootView(coordinator: coordinator)
      .task { await start() }
  }

  private func start() async {
    guard !Self.isTestHost else { return }
    coordinator.start()
    #if DEBUG
      // `-BlurtStartListening` opens the mic at launch, so the listening
      // state can be screenshotted without a tap (see scripts/ios-sim.sh).
      // Asking for it stands in for consent, which a screenshot or probe run
      // can't tap through; debug builds only.
      if CommandLine.arguments.contains("-BlurtStartListening") { await coordinator.grantConsent() }
    #endif
  }
}
